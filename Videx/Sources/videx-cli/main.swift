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
        var jar = CookieJar()

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
            case "--clients":
                index += 1
                if index < args.count {
                    selectedClients = args[index].split(separator: ",").map(String.init)
                }
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
            log: verbose ? StderrLogSink(minLevel: .debug) : StderrLogSink(minLevel: .warn)
        )
        let registry = ExtractorRegistry(extractors: [
            YouTubeExtractor(clientOrder: clientOrder(from: selectedClients)),
            BilibiliExtractor(),
            DouyinExtractor(),
            TikTokExtractor(),
        ])

        var exitCode = 0
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else {
                FileHandle.standardError.write(Data("无效 URL: \(urlString)\n".utf8))
                exitCode = 1
                continue
            }
            do {
                let info = try await registry.extract(url: url, options: options)
                if jsonOutput {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(data: try encoder.encode(info), encoding: .utf8) ?? "{}")
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

    /// "ios,web" → 对应客户端配置；未知名字忽略。
    static func clientOrder(from names: [String]?) -> [InnerTubeClient.ClientConfig] {
        guard let names, !names.isEmpty else { return InnerTubeClient.defaultClientOrder }
        let all: [String: InnerTubeClient.ClientConfig] = [
            "ios": InnerTubeClient.ios, "android": InnerTubeClient.android, "android_vr": InnerTubeClient.androidVr,
            "tv": InnerTubeClient.tvEmbedded, "web": InnerTubeClient.web,
        ]
        let chosen = names.compactMap { all[$0.lowercased()] }
        return chosen.isEmpty ? InnerTubeClient.defaultClientOrder : chosen
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

    static func printUsage() {
        print("""
        videx — 视频/音频流提取（YouTube & Bilibili）

        用法:
          videx <url>... [选项]

        选项:
          --proxy <url>    代理，如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7891
          --cookie k=v     注入 Cookie（SESSDATA → bilibili，其余 → youtube）
          --clients <list>  指定 YouTube 客户端轮询顺序（ios,android_vr,android,tv,web）
          --json           输出 MediaInfo JSON
          -v / --verbose   详细日志
        """)
    }
}
