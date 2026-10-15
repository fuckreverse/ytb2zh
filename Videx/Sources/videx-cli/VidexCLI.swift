import Foundation
import Videx

@main
struct VidexCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var proxy: String?
        var jsonOutput = false
        var verbose = false
        var urlStrings: [String] = []
        var selectedClients: [String]?
        var allowMissingPot = false
        var jar = CookieJar()
        var poTokens: [String: String] = [:]
        var visitorData: String?
        var downloadMedia = false, expandPlaylist = false, writeSubtitles = false
        var comments = false, chat = false, chatReplay = false, liveFromStart = false
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("videx-downloads")
        var formatExpression = "bv+ba/b"
        var archiveURL: URL?, duration: Double?, start: Double = 0
        var languages = ["en"], maxItems = 200, maxPages = 1


        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--proxy":
                index += 1; if index < args.count { proxy = args[index] }
            case "--json":
                jsonOutput = true
            case "--verbose", "-v":
                verbose = true
            case "--allow-missing-pot":
                allowMissingPot = true
            case "--clients":
                index += 1
                if index < args.count {
                    selectedClients = args[index].split(separator: ",").map(String.init)
                }
            case "--download": downloadMedia = true
            case "--playlist": expandPlaylist = true
            case "--write-subs": writeSubtitles = true
            case "--comments": comments = true
            case "--chat": chat = true
            case "--chat-replay": chat = true; chatReplay = true
            case "--live-from-start": liveFromStart = true
            case "--output", "--format", "-f", "--archive", "--duration", "--start", "--sub-langs", "--max-items", "--max-pages", "--cookies-from-browser":
                index += 1
                guard index < args.count else { fail("\(arg) 缺少值") }
                let value = args[index]
                switch arg {
                case "--output": directory = URL(fileURLWithPath: value)
                case "--format", "-f": formatExpression = value
                case "--archive": archiveURL = URL(fileURLWithPath: value)
                case "--duration": guard let number = Double(value), number > 0, number.isFinite else { fail("--duration 需要正数秒") }; duration = number
                case "--start": guard let number = Double(value), number >= 0, number.isFinite else { fail("--start 需要非负秒") }; start = number
                case "--sub-langs": languages = value.split(separator: ",").map(String.init)
                case "--max-items": guard let number = Int(value), number > 0 else { fail("--max-items 需要正整数") }; maxItems = number
                case "--max-pages": guard let number = Int(value), number > 0 else { fail("--max-pages 需要正整数") }; maxPages = number
                case "--cookies-from-browser":
                    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { fail("格式为 firefox:/path/cookies.sqlite、chrome:/path/Cookies 或 safari:/path/Cookies.binarycookies") }
                    let file = URL(fileURLWithPath: parts[1])
                    do {
                        switch parts[0] {
                        case "firefox": jar = try BrowserCookies.firefox(database: file)
                        case "chrome": jar = try BrowserCookies.chromium(database: file)
                        case "safari": jar = try BrowserCookies.safari(file: file)
                        default: fail("不支持的浏览器")
                        }
                    } catch { fail("浏览器会话导入失败：\(error.localizedDescription)") }
                default: break
                }
            case "--cookies":
                index += 1
                guard index < args.count else { fail("--cookies 缺少文件路径") }
                do {
                    jar = try CookieJar(netscape: String(contentsOfFile: args[index], encoding: .utf8))
                } catch { fail("无法读取 Cookie 文件：\(error.localizedDescription)") }
            case "--visitor-data":
                index += 1
                guard index < args.count, !args[index].isEmpty else { fail("--visitor-data 缺少值") }
                visitorData = args[index]
            case "--po-token":
                index += 1
                guard index < args.count else { fail("--po-token 缺少 client.context+token") }
                let token = args[index].split(separator: "+", maxSplits: 1)
                guard token.count == 2, !token[1].isEmpty,
                      token[0].hasSuffix(".gvs") || token[0].hasSuffix(".player") || token[0].hasSuffix(".subs") else {
                    fail("PO Token 格式为 client.gvs+token、client.player+token 或 client.subs+token")
                }
                poTokens[String(token[0])] = String(token[1])
            case "--cookie":
                index += 1
                if index < args.count {
                    let parts = args[index].split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let name = String(parts[0])
                        let domain: String
                        switch name {
                        case "SESSDATA": domain = ".bilibili.com"
                        case "sessionid", "ttwid": domain = ".douyin.com"
                        default: domain = ".youtube.com"
                        }
                        jar.set(SiteCookie(name: name, value: String(parts[1]), domain: domain))
                    }
                }
            case "--help", "-h":
                printUsage()
                return
            default:
                urlStrings.append(arg)
            }
            index += 1
        }

        guard !urlStrings.isEmpty else {
            printUsage()
            exit(2)
        }

        let options = ExtractionOptions(
            proxy: proxy,
            cookies: jar,
            log: verbose ? StderrLogSink(minLevel: .debug) : StderrLogSink(minLevel: .warn),
            includeFormatsMissingPoToken: allowMissingPot,
            youtubePoTokens: poTokens,
            youtubeVisitorData: visitorData
        )
        let registry = ExtractorRegistry(extractors: [
            YouTubeExtractor(clientOrder: clientOrder(from: selectedClients)),
            BilibiliExtractor(),
            DouyinExtractor(),
            TikTokExtractor(),
        ])

        if expandPlaylist {
            do {
                var expanded: [String] = []
                for input in urlStrings {
                    expanded += try await BatchDownloadRunner.playlistURLs(query: input, limit: maxItems, options: options).map(\.absoluteString)
                }
                urlStrings = expanded
            } catch { fail("播放列表读取失败：\(error.localizedDescription)") }
        }
        let archive = archiveURL.map { DownloadArchive(url: $0) }
        var exitCode = 0
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else {
                FileHandle.standardError.write(Data("无效 URL: \(urlString)\n".utf8))
                exitCode = 1
                continue
            }
            do {
                let archiveKey = "youtube " + (YouTubeURL.videoID(from: url) ?? url.absoluteString)
                if downloadMedia, try await archive?.contains(archiveKey) == true {
                    FileHandle.standardError.write(Data("已归档，跳过 \(url.absoluteString)\n".utf8))
                    continue
                }
                let info = try await registry.extract(url: url, options: options)
                if downloadMedia {
                    let output = try await Self.download(info: info, url: url, registry: registry, options: options,
                        expression: formatExpression, directory: directory, start: start, duration: duration, liveFromStart: liveFromStart)
                    try await archive?.record(archiveKey, output: output)
                }
                if writeSubtitles {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let http = RetryingHTTPClient(base: URLSessionHTTPClient(proxy: proxy))
                    for track in info.subtitles where languages.contains("all") || languages.contains(track.language) {
                        let name = info.id + "." + track.language + (track.isTranslated == true ? ".translated" : "") + ".srt"
                        let text = try await SubtitleConverter.fetchSRT(track, client: http)
                        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    }
                }
                if comments || chat {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let service = YouTubeDiscussionService()
                    if comments {
                        var items: [YouTubeComment] = [], token: String?, tokens = Set<String>(), seen = Set<String>()
                        for _ in 0..<maxPages {
                            try Task.checkCancellation()
                            let page = try await service.comments(videoID: info.id, continuation: token, options: options)
                            items += page.comments.filter { seen.insert($0.id).inserted }
                            guard let next = page.continuation, tokens.insert(next).inserted else { break }
                            token = next
                        }
                        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent(info.id + ".comments.json"), options: .atomic)
                    }
                    if chat {
                        var items: [YouTubeChatMessage] = [], token: String?, tokens = Set<String>(), seen = Set<String>()
                        for _ in 0..<maxPages {
                            try Task.checkCancellation()
                            let page = try await service.chat(videoID: info.id, continuation: token, replay: chatReplay, options: options)
                            items += page.messages.filter { seen.insert($0.id).inserted }
                            guard let next = page.continuation, tokens.insert(next).inserted else { break }
                            token = next
                            if !chatReplay { try await Task.sleep(for: .milliseconds(min(60000,max(500,page.pollAfterMilliseconds ?? 1000)))) }
                        }
                        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent(info.id + ".chat.json"), options: .atomic)
                    }
                }
                if jsonOutput {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    // MediaInfo 的 bestVideoOnly/bestAudioOnly 是计算属性，
                    // JSONEncoder 不会编码——编码后手动补进字典。
                    var dict = (try? JSONSerialization.jsonObject(with: try encoder.encode(info)))
                        as? [String: Any] ?? [:]
                    for (key, best) in [("bestVideoOnly", info.bestVideoOnly),
                                        ("bestAudioOnly", info.bestAudioOnly)] {
                        if let best, let data = try? encoder.encode(best),
                           let obj = try? JSONSerialization.jsonObject(with: data) {
                            dict[key] = obj
                        }
                    }
                    let out = try JSONSerialization.data(
                        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: out, encoding: .utf8) ?? "{}")
                } else {
                    printHumanReadable(info)
                }
            } catch {
                FileHandle.standardError.write(Data("❌ \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
        }
        exit(Int32(exitCode))
    }

    /// "ios,web" → 对应客户端配置；nil = 未指定（按 Cookie 有无自动选择）。
    /// 未知名字忽略；全部未知时同样回落自动选择。
    static func clientOrder(from names: [String]?) -> [InnerTubeClient.ClientConfig]? {
        guard let names, !names.isEmpty else { return nil }
        let all: [String: InnerTubeClient.ClientConfig] = [
            "tv_samsung": InnerTubeClient.tvSamsung,
            "visionos": InnerTubeClient.visionos,
            "web_embedded": InnerTubeClient.webEmbedded,
            "tv_downgraded": InnerTubeClient.tvDowngraded,
            "tv_simply": InnerTubeClient.tvSimply,
            "ios": InnerTubeClient.ios,
            "android": InnerTubeClient.android,
            "android_vr": InnerTubeClient.androidVr,
            "web": InnerTubeClient.web,
            "web_safari": InnerTubeClient.webSafari,
            "mweb": InnerTubeClient.mweb,
        ]
        let chosen = names.compactMap { all[$0.lowercased()] }
        return chosen.isEmpty ? nil : chosen
    }

    static func printHumanReadable(_ info: MediaInfo) {
        print("📽  \(info.title)")
        print("🌐  \(info.webpageURL.absoluteString)")
        if let uploader = info.uploader { print("👤  \(uploader)  •  👀 \(info.viewCount.map(String.init) ?? "-")") }
        if let duration = info.duration { print(String(format: "⏱  %.0fs", duration)) }
        print("🧩  提取器: \(info.extractorID)  •  \(info.formats.count) 条流  •  \(info.subtitles.count) 条字幕")
        print("")
        print("  格式           类型       编码                分辨率     码率")
        print("  ────────────────────────────────────────────────────────────")
        for f in info.formats {
            let codec = f.videoCodec ?? f.audioCodec ?? "-"
            let res = f.height.map { "\(f.width ?? 0)x\($0)" } ?? "-"
            let bitrate = f.averageBitrate.map { String(format: "%.0fk", Double($0) / 1000) } ?? "-"
            print("  \(pad(f.formatID, 14))\(pad(f.kind.rawValue, 10))\(pad(codec, 19))\(pad(res, 10))\(bitrate)")
        }
        if !info.subtitles.isEmpty {
            print("")
            print("  字幕: " + info.subtitles.map { "\($0.language)(\( $0.isAutoGenerated ? "auto" : "manual"))" }.joined(separator: ", "))
        }
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    static func printUsage() {
        print("""
        videx — 视频/音频流提取（YouTube & Bilibili）

        用法:
          videx <url>... [选项]

        选项:
          --download         原生下载，已有 ffmpeg 仅负责封装/合流
          --output <dir>     输出目录（默认 videx-downloads）
          --format / -f <expr>  格式表达式，默认 bv+ba/b
          --duration <sec> --start <sec> --live-from-start  截段/直播控制
          --playlist --max-items <n>  批量读取频道/播放列表
          --archive <file>   成功下载归档去重
          --write-subs --sub-langs <langs>  保存字幕，逗号分隔或 all
          --comments --chat --chat-replay  保存评论/聊天；--max-pages N 控制页数（默认 1）
          --cookies-from-browser <browser:path>  原生导入明确指定的浏览器文件
          --proxy <url>    代理，如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7891
          --cookies <file>  导入 Netscape cookies.txt（只读取明确指定的文件）
          --po-token <client.context+token>  外部 PO Token（gvs/player/subs），可重复指定
          --visitor-data <value>  与外部访客 GVS Token 配套的 visitorData
          --cookie k=v     注入 Cookie（SESSDATA → bilibili，其余 → youtube）
          --clients <list>  指定 YouTube 客户端轮询顺序，逗号分隔。可用：
                           tv_samsung, visionos, web_embedded, tv_downgraded,
                           tv_simply, ios, android, android_vr, web, web_safari, mweb
                           （访客：tv_samsung,visionos,web；
                            有效登录会话：web_embedded,tv_samsung,web）
          --allow-missing-pot  保留缺 GVS PO Token 的格式（下载可能 403，调试用）
          --json           输出 MediaInfo JSON
          -v / --verbose   详细日志
        """)
    }
}
