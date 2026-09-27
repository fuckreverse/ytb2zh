import Foundation

// MARK: - JobStore：任务目录布局 + 步骤状态（断点续跑 / 增量重跑）

public struct JobStore: Sendable {
    public enum StepState: String, Codable { case pending, running, done, failed }

    public struct Status: Codable {
        public var url: String
        public var profileName: String
        public var createdAt: Date
        public var steps: [String: StepState]

        public init(url: String = "", profileName: String = "", createdAt: Date = Date(),
                    steps: [String: StepState] = [:]) {
            self.url = url; self.profileName = profileName; self.createdAt = createdAt
            self.steps = steps
        }
    }

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ytb2ZH/Jobs", isDirectory: true)
    }

    // MARK: 产物路径约定

    public func jobDir(id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func source(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("source.mp4") }
    public func vocalsWav(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("vocals.wav") }
    public func instrumentalWav(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("instrumental.wav") }
    public func audioWav(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("audio16k.wav") }
    public func wordsJSON(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("words.json") }
    public func unitsJSON(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("units.json") }
    public func terminologyJSON(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("terminology.json") }
    public func translatedJSON(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("translated.json") }
    public func clauseCache(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("clauses", isDirectory: true) }
    public func planJSON(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("plan.json") }
    public func dubWav(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("dub.wav") }
    public func subtitles(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("zh.srt") }
    public func finalVideo(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("final_zh.mp4") }
    public func statusFile(_ id: String) -> URL { jobDir(id: id).appendingPathComponent("status.json") }

    public func newJob(url: String, profile: Profile) throws -> String {
        let id = String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString.prefix(6)
        try FileManager.default.createDirectory(at: jobDir(id: id), withIntermediateDirectories: true)
        var st = Status(url: url, profileName: profile.name)
        for s in StepID.allCases { st.steps[s.rawValue] = .pending }
        saveStatus(id, st)
        // 参数快照：GUI 续跑时取回完整参数
        try? writeJSON(profile, to: jobDir(id: id).appendingPathComponent("profile.json"))
        return id
    }

    public func loadStatus(_ id: String) -> Status {
        guard let data = try? Data(contentsOf: statusFile(id)),
              let st = try? JSONDecoder().decode(Status.self, from: data) else { return Status() }
        return st
    }

    public func saveStatus(_ id: String, _ status: Status) {
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: statusFile(id))
        }
    }

    public func setStep(_ id: String, _ step: StepID, _ state: StepState) {
        var st = loadStatus(id)
        st.steps[step.rawValue] = state
        saveStatus(id, st)
    }

    public func stepState(_ id: String, _ step: StepID) -> StepState {
        loadStatus(id).steps[step.rawValue] ?? .pending
    }

    public func allJobs() -> [(id: String, status: Status)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { fm.fileExists(atPath: statusFile($0.lastPathComponent).path) }
            .map { ($0.lastPathComponent, loadStatus($0.lastPathComponent)) }
            .sorted { $0.1.createdAt > $1.1.createdAt }
    }

    // MARK: 产物读写

    public func readJSON<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(value).write(to: url)
    }
}

// MARK: - EngineRegistry：GUI / CLI 的可插拔发现点

public struct EngineRegistry: Sendable {
    public struct Offer: Sendable, Hashable {
        public let step: StepID
        public let descriptors: [EngineDescriptor]

        public init(step: StepID, descriptors: [EngineDescriptor]) {
            self.step = step; self.descriptors = descriptors
        }
    }

    public let offers: [Offer]

    public init(_ offers: [Offer]) { self.offers = offers }

    public func descriptors(for step: StepID) -> [EngineDescriptor] {
        offers.first { $0.step == step }?.descriptors ?? []
    }

    public func descriptor(_ id: String, step: StepID) -> EngineDescriptor? {
        descriptors(for: step).first { $0.id == id }
    }

    public func validate(profile: Profile) -> [String] {
        var errors: [String] = []
        for step in StepID.allCases {
            guard let id = profile.engines[step.rawValue] else {
                errors.append("\(step.label)：未选择引擎"); continue
            }
            if descriptor(id, step: step) == nil {
                errors.append("\(step.label)：引擎 \(id) 不存在")
            }
        }
        return errors
    }
}
