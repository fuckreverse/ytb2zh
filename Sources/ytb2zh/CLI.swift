import Foundation
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - ytb2zh CLI：run / templates / providers，JSON 事件流输出

@main
struct Ytb2ZHCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "run": try await cmdRun(Array(args.dropFirst()))
            case "batch": try await cmdBatch(Array(args.dropFirst()))
            case "templates": cmdTemplates(Array(args.dropFirst()))
            case "providers": cmdProviders()
            case "jobs": cmdJobs()
            case "verify": try await VerifyCommand.run(Array(args.dropFirst()))
            case "tts-probe": try await TTSProbe.run(Array(args.dropFirst()))
            case "help", "--help", "-h", nil: printUsage()
            default:
                fputs("未知命令：\(args[0])\n", stderr)
                printUsage()
                exit(2)
            }
        } catch {
            fputs("错误：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        ytb2zh — 英文视频 → 中文字幕 + 中文配音

        用法:
          ytb2zh run <url|本地路径> [--profile <name>] [--job-dir <dir>] [--from <step>] [--steps <s1,s2>]
                        [--srt <file.srt>] [--resume <jobID>] [--trial-seconds <N>] [--set key=value ...]
          ytb2zh batch <tasks.json>   批量任务（重跑时跳过 done、重试 failed）
          ytb2zh templates list [--json]
          ytb2zh templates save <name> [--base <name>] [--set key=value ...]
          ytb2zh templates delete <name>
          ytb2zh providers
          ytb2zh jobs
          ytb2zh verify [--media <path>]

        run 事件流（每行一个 JSON）:
          {"event":"stepStarted","step":"download"}
          {"event":"progress","step":"download","pct":0.42,"msg":"..."}
          {"event":"stepFinished","step":"translate","info":{...}}
          {"event":"failed","step":"synthesize","error":"..."}

        --trial-seconds N：试转模式，新任务只处理前 N 秒（下载段截断 + ffmpeg 截取），
                          用于低成本验证配置；确认后再跑全片。

        --set 可调项（key=dotted.path:value，JSON 值类型自动解析）:
          schedule.driftCap=1.2  schedule.pauseMax=1.0  compose.subtitleFontSize=18
          translate.style=narrator  translate.quality=threePass  synth.voice=longsanshu_v3.1

        步骤 id: download/separate/transcribe/segment/summarize/translate/synthesize/schedule/compose
        """)
    }

    // MARK: run

    struct RunOptions {
        var url = ""
        var profileName = "均衡（默认）"
        var from: StepID?
        var steps: Set<StepID> = []
        var jobDir: String?
        var srt: String?
        var resumeJobID: String?
        var trialSeconds: Int?
        var overrides: [(String, String)] = []
    }

    static func cmdRun(_ args: [String]) async throws {
        var o = RunOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--profile": i += 1; o.profileName = args[i]
            case "--from": i += 1; o.from = StepID(rawValue: args[i])
            case "--steps":
                i += 1
                o.steps = Set(args[i].split(separator: ",").compactMap { StepID(rawValue: String($0)) })
            case "--job-dir": i += 1; o.jobDir = args[i]
            case "--srt":
                i += 1; o.srt = args[i]
            case "--resume":
                i += 1; o.resumeJobID = args[i]
            case "--trial-seconds":
                i += 1; o.trialSeconds = Int(args[i])
            case "--set":
                i += 1
                let kv = args[i].split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { throw EngineError.engineFailure("--set 需要 key=value") }
                o.overrides.append((String(kv[0]), String(kv[1])))
            default: o.url = args[i]
            }
            i += 1
        }
        guard !o.url.isEmpty else { throw EngineError.engineFailure("缺少视频 URL 或本地路径") }

        // 模板 + 覆盖
        var profile = try resolveProfile(name: o.profileName)
        if let srt = o.srt {
            guard FileManager.default.fileExists(atPath: (srt as NSString).expandingTildeInPath) else {
                throw EngineError.engineFailure("SRT 文件不存在：\(srt)")
            }
            profile.engines[StepID.transcribe.rawValue] = "srt"
            profile.transcribe.srtPath = srt
        }
        for (key, value) in o.overrides { try applyOverride(&profile, key: key, value: value) }

        // 注册表校验
        let errors = EngineAssembly.registry().validate(profile: profile)
        guard errors.isEmpty else { throw EngineError.notConfigured(errors.joined(separator: "；")) }

        // Job（--resume 续跑已有任务；否则新建）
        let store = o.jobDir.map { JobStore(root: URL(fileURLWithPath: $0)) } ?? JobStore()
        let jobID: String
        if let resume = o.resumeJobID {
            jobID = resume
        } else {
            jobID = try store.newJob(url: o.url, profile: profile, trial: o.trialSeconds != nil)
        }

        let (stream, cont) = AsyncStream<PipelineEvent>.makeStream()
        let pipeline = Pipeline(engines: try EngineAssembly.engineSet(for: profile),
                                store: store, events: cont)

        // 事件流 → stdout JSON（后台打印，主任务跑管线）
        let printer = Task {
            for await e in stream { print(Self.eventJSON(e)); fflush(stdout) }
        }

        var stepFilter = o.steps
        if let f = o.from {
            let order = StepID.allCases
            stepFilter = Set(order.filter { order.firstIndex(of: $0)! >= order.firstIndex(of: f)! })
        }
        _ = try await pipeline.run(videoURL: nil, url: o.url, profile: profile,
                                   jobID: jobID, stepFilter: stepFilter,
                                   trialSeconds: o.trialSeconds)
        cont.finish()
        await printer.value
    }

    // MARK: templates

    static func cmdTemplates(_ args: [String]) {
        let store = TemplateStore()
        switch args.first {
        case "list":
            let asJSON = args.contains("--json")
            for e in store.all() {
                if asJSON {
                    let data = try? JSONEncoder().encode(e.profile)
                    print("\(e.id)\t\(String(data: data ?? Data(), encoding: .utf8) ?? "{}")")
                } else {
                    let tag = e.location == .builtin ? "内置" : "用户"
                    print("[\(tag)] \(e.profile.name)")
                }
            }
        case "save":
            guard args.count >= 2 else { fputs("templates save <name>\n", stderr); exit(2) }
            let name = args[1]
            var base = Profile.balanced
            if let bi = args.firstIndex(of: "--base"), bi + 1 < args.count {
                base = (try? resolveProfile(name: args[bi + 1])) ?? Profile.balanced
            }
            var profile = base.derived(named: name)
            if let si = args.firstIndex(of: "--set") {
                for kv in args[(si + 1)...] {
                    let parts = kv.split(separator: "=", maxSplits: 1)
                    if parts.count == 2, let err = nilCheck({ try applyOverride(&profile, key: String(parts[0]), value: String(parts[1])) }) {
                        fputs("覆盖失败 \(kv)：\(err)\n", stderr); exit(2)
                    }
                }
            }
            do { try store.save(profile); print("已保存模板：\(name)") }
            catch { fputs("保存失败：\(error.localizedDescription)\n", stderr); exit(1) }
        case "delete":
            guard args.count >= 2 else { fputs("templates delete <name>\n", stderr); exit(2) }
            do { try store.delete(Profile(name: args[1])); print("已删除模板：\(args[1])") }
            catch { fputs("删除失败：\(error.localizedDescription)\n", stderr); exit(1) }
        default:
            fputs("templates list|save|delete\n", stderr); exit(2)
        }
    }

    static func nilCheck(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    // MARK: providers / jobs

    static func cmdProviders() {
        let registry = EngineAssembly.registry()
        for offer in registry.offers {
            let list = offer.descriptors.map { "\($0.id)（\($0.name)）" }.joined(separator: "  ")
            print("\(offer.step.rawValue)\t\(offer.step.label)\t\(list)")
        }
    }

    static func cmdJobs() {
        for (id, st) in JobStore().allJobs() {
            let done = st.steps.values.filter { $0 == .done }.count
            print("\(id)\t\(st.profileName)\t\(done)/\(StepID.allCases.count) done")
        }
    }

    // MARK: batch

    struct BatchTask: Decodable {
        var url: String
        var profile: String?
        var srt: String?
        var set: [String: String]?   // dotted.path -> value
    }

    /// 批量任务：顺序执行，逐任务隔离；重跑时 done 步骤自动跳过、failed 重试
    static func cmdBatch(_ args: [String]) async throws {
        var path: String?
        var jobDir: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--job-dir": i += 1; jobDir = args[i]
            default: path = args[i]
            }
            i += 1
        }
        guard let path else { throw EngineError.engineFailure("用法：ytb2zh batch <tasks.json>") }
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let tasks: [BatchTask]
        if let single = try? JSONDecoder().decode(BatchTask.self, from: data) {
            tasks = [single]
        } else {
            tasks = try JSONDecoder().decode([BatchTask].self, from: data)
        }
        guard !tasks.isEmpty else { throw EngineError.engineFailure("tasks.json 为空") }

        let store = jobDir.map { JobStore(root: URL(fileURLWithPath: $0)) } ?? JobStore()
        var failures: [String] = []
        for (n, t) in tasks.enumerated() {
            print("\n===== [\(n + 1)/\(tasks.count)] \(t.url) =====")
            do {
                var profile = try resolveProfile(name: t.profile ?? "均衡（默认）")
                if let srt = t.srt {
                    profile.engines[StepID.transcribe.rawValue] = "srt"
                    profile.transcribe.srtPath = srt
                }
                for (k, v) in t.set ?? [:] { try applyOverride(&profile, key: k, value: v) }
                let errors = EngineAssembly.registry().validate(profile: profile)
                guard errors.isEmpty else { throw EngineError.notConfigured(errors.joined(separator: "；")) }

                // 断点语义：同 URL 且参数完全一致的任务复用（重跑跳过 done、重试 failed）；否则新建
                let existing = store.allJobs().first { entry -> Bool in
                    guard entry.1.url == t.url, entry.1.profileName == profile.name else { return false }
                    let saved = store.readJSON(store.jobDir(id: entry.0)
                        .appendingPathComponent("profile.json"), as: Profile.self)
                    return saved == profile
                }
                let jobID: String
                if let (id, _) = existing {
                    jobID = id
                    print("复用已有任务 \(id)")
                } else {
                    jobID = try store.newJob(url: t.url, profile: profile)
                }
                let st = store.loadStatus(jobID)
                let retry = Set(st.steps.filter { $0.value != .done }.keys.compactMap { StepID(rawValue: $0) })
                guard !retry.isEmpty else {
                    print("全部步骤已完成，跳过：job \(jobID) -> \(store.finalVideo(jobID).path)")
                    continue
                }

                let (stream, cont) = AsyncStream<PipelineEvent>.makeStream()
                let pipeline = Pipeline(engines: try EngineAssembly.engineSet(for: profile),
                                        store: store, events: cont)
                let printer = Task { for await e in stream { print(Self.eventJSON(e)) } }
                _ = try await pipeline.run(videoURL: nil, url: t.url, profile: profile,
                                           jobID: jobID, stepFilter: retry)
                cont.finish()
                await printer.value
                print("----- 完成：job \(jobID) -> \(store.finalVideo(jobID).path)")
            } catch {
                failures.append("\(t.url)：\(error.localizedDescription)")
                print("----- 失败：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw EngineError.engineFailure("\(failures.count)/\(tasks.count) 个任务失败：\n" + failures.joined(separator: "\n"))
        }
    }

    // MARK: helpers

    static func resolveProfile(name: String) throws -> Profile {
        if let b = Profile.builtins.first(where: { $0.name == name }) { return b }
        let store = TemplateStore()
        if let u = store.loadUserTemplates().first(where: { $0.profile.name == name }) {
            return u.profile
        }
        throw EngineError.notConfigured("模板不存在：\(name)（ytb2zh templates list 查看）")
    }

    static func applyOverride(_ profile: inout Profile, key: String, value: String) throws {
        let jsonValue: Any = {
            if let d = Int(value) { return d }
            if let d = Double(value) { return d }
            if value == "true" { return true }
            if value == "false" { return false }
            return value
        }()
        guard let data = try? JSONSerialization.data(withJSONObject: [key: jsonValue],
                                                     options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject([key: jsonValue]) || true else {
            throw EngineError.engineFailure("无法解析值：\(key)=\(value)")
        }
        // 用 JSONDecoder 完整走一遍（保留未知字段）
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let profileData = try? enc.encode(profile),
              var obj = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
            throw EngineError.engineFailure("Profile 序列化失败")
        }
        // dotted.path → 嵌套
        let parts = key.split(separator: ".").map(String.init)
        func inject(_ obj: inout [String: Any], _ parts: [String], _ v: Any) {
            guard let first = parts.first else { return }
            if parts.count == 1 {
                obj[first] = v
            } else {
                var sub = (obj[first] as? [String: Any]) ?? [:]
                inject(&sub, Array(parts.dropFirst()), v)
                obj[first] = sub
            }
        }
        inject(&obj, parts, jsonValue)
        let merged = try JSONSerialization.data(withJSONObject: obj)
        let fixed = try JSONDecoder().decode(Profile.self, from: merged)
        profile = fixed
        _ = data
    }

    static func eventJSON(_ e: PipelineEvent) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        struct EventDTO: Encodable {
            var event: String
            var step: String?
            var pct: Double?
            var msg: String?
            var info: [String: String]?
            var error: String?
        }
        let dto: EventDTO
        switch e {
        case .stepStarted(let s):
            dto = EventDTO(event: "stepStarted", step: s.rawValue, pct: nil, msg: nil, info: nil, error: nil)
        case .progress(let s, let p, let m):
            dto = EventDTO(event: "progress", step: s.rawValue, pct: (p * 1000).rounded() / 1000, msg: m, info: nil, error: nil)
        case .stepFinished(let s, let info):
            dto = EventDTO(event: "stepFinished", step: s.rawValue, pct: nil, msg: nil, info: info, error: nil)
        case .log(let m):
            dto = EventDTO(event: "log", step: nil, pct: nil, msg: m, info: nil, error: nil)
        case .failed(let s, let err):
            dto = EventDTO(event: "failed", step: s.rawValue, pct: nil, msg: nil, info: nil, error: err)
        }
        return String(data: (try? enc.encode(dto)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
