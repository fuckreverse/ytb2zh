import Foundation
import Ytb2ZHEngines

// 隐藏子命令：orig-probe <url> [--proxy <p>] [--range]
// 快路径验证「看原版」整条链路（不经 GUI）：
//   yt-dlp 解析 → 本地回环反代 → master m3u8 → media playlist（改写）→ 分片字节
//   progressive 时验证 Range 透传（任意拖进度的前提）。

enum OrigProbe {
    /// --raw 模式：跳过 yt-dlp，直接以 progressive 模式反代给定上游（验证 Range 透传）
    static func runRaw(upstream: String, proxy: String) async throws {
        guard let up = URL(string: upstream) else {
            throw EngineError.engineFailure("--raw 上游 URL 无效")
        }
        print("① progressive 直连模式（跳过解析）：\(up.absoluteString)")
        let server = OrigStreamServer(kind: .progressive(url: up.absoluteString), proxy: proxy)
        try server.start()
        defer { server.stop() }
        guard let play = server.localPlayURL else {
            throw EngineError.engineFailure("本地反代未就绪")
        }
        print("② 本地反代就绪：\(play)")
        let session = URLSession(configuration: .ephemeral)
        func get(_ u: URL, range: String?) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: u)
            if let range { req.setValue(range, forHTTPHeaderField: "Range") }
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw EngineError.engineFailure("非 HTTP 响应")
            }
            return (data, http)
        }
        print("③ Range 透传验证…")
        let (head, r1) = try await get(play, range: "bytes=0-1023")
        print("   bytes=0-1023 → \(r1.statusCode)  content-range=\(r1.value(forHTTPHeaderField: "Content-Range") ?? "-")  got=\(head.count)B")
        guard r1.statusCode == 206 || r1.statusCode == 200 else {
            throw EngineError.engineFailure("Range 请求失败：\(r1.statusCode)")
        }
        let (mid, r2) = try await get(play, range: "bytes=1000000-1000047")
        print("   bytes=1000000-1000047 → \(r2.statusCode)  got=\(mid.count)B")
        print("✅ progressive 链路 OK（Range 任意拖进度可用）")
    }

    static func run(_ args: [String]) async throws {
        var url: String?
        var proxy = "http://127.0.0.1:7890"
        var raw: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--proxy": i += 1; proxy = args[i]
            case "--raw": i += 1; raw = args[i]      // 跳过 yt-dlp，直接用给定上游（progressive）
            default: url = args[i]
            }
            i += 1
        }
        if let raw {
            try await runRaw(upstream: raw, proxy: proxy)
            return
        }
        guard let url, !url.isEmpty else {
            throw EngineError.engineFailure("用法：ytb2zh orig-probe <url> [--proxy <p>] | --raw <upstream-url>")
        }

        print("① 解析原版流（yt-dlp -j，proxy=\(proxy)）…")
        let info = try OrigStreamService().resolve(url: url, proxy: proxy)
        print("   title: \(info.title)")
        print("   duration: \(Int(info.duration))s")
        switch info.kind {
        case .progressive(let u): print("   kind: progressive  \(String(u.prefix(90)))…")
        case .hls(let v, let a):
            print("   kind: hls")
            print("   video: \(String(v.prefix(90)))…")
            print("   audio: \(String(a.prefix(90)))…")
        }

        let server = OrigStreamServer(kind: info.kind, proxy: info.proxyOverride ?? proxy, requestHeaders: info.requestHeaders)
        try server.start()
        defer { server.stop() }
        guard let play = server.localPlayURL else {
            throw EngineError.engineFailure("本地反代未就绪")
        }
        print("② 本地反代就绪：\(play)")

        let session = URLSession(configuration: .ephemeral)   // loopback，无需代理

        func get(_ u: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: u)
            if let range { req.setValue(range, forHTTPHeaderField: "Range") }
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw EngineError.engineFailure("非 HTTP 响应")
            }
            return (data, http)
        }

        switch info.kind {
        case .progressive:
            print("③ Range 透传验证…")
            let (head, r1) = try await get(play, range: "bytes=0-1023")
            print("   bytes=0-1023 → \(r1.statusCode)  content-range=\(r1.value(forHTTPHeaderField: "Content-Range") ?? "-")  got=\(head.count)B")
            guard r1.statusCode == 206 || r1.statusCode == 200 else {
                throw EngineError.engineFailure("Range 请求失败：\(r1.statusCode)")
            }
            let (mid, r2) = try await get(play, range: "bytes=1000000-1000047")
            print("   bytes=1000000-1000047 → \(r2.statusCode)  got=\(mid.count)B")
            print("✅ progressive 链路 OK（Range 任意拖进度可用）")

        case .hls:
            print("③ 走 master → media playlist → 分片 …")
            var cur = play
            var depth = 0
            while depth < 4 {
                let (data, resp) = try await get(cur)
                let text = String(decoding: data, as: UTF8.self)
                let isList = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("mpegurl")
                    || text.hasPrefix("#EXTM3U")
                print("   GET \(cur.path.isEmpty ? cur.absoluteString : cur.path) → \(resp.statusCode) \(data.count)B list=\(isList)")
                guard resp.statusCode == 200 else {
                    throw EngineError.engineFailure("反代返回 \(resp.statusCode)")
                }
                if !isList {
                    guard data.first == 0x47 else {
                        throw EngineError.engineFailure("分片首字节非 TS 同步字节 0x47（got 0x\(String(data.first ?? 0, radix: 16))）")
                    }
                    print("   分片首字节 0x47 ✓（MPEG-TS）")
                    break
                }
                // 取下一跳：master → 视频流 URI；media playlist → 第一个分片 URI
                var next: String?
                if depth == 0, cur.lastPathComponent.hasPrefix("master") {
                    next = text.split(separator: "\n")
                        .first { !$0.hasPrefix("#") && !$0.isEmpty }
                        .map(String.init)
                } else {
                    next = text.split(separator: "\n")
                        .first { !$0.hasPrefix("#") && !$0.isEmpty }
                        .map(String.init)
                }
                guard let n = next, let nu = URL(string: n, relativeTo: cur) else {
                    throw EngineError.engineFailure("m3u8 内未找到下一跳 URI")
                }
                cur = nu.absoluteURL
                depth += 1
            }
            if depth >= 4 { throw EngineError.engineFailure("m3u8 层级超限") }

            // 音频轨也抽验一跳
            let (mdata, _) = try await get(play)
            let mtext = String(decoding: mdata, as: UTF8.self)
            if let audioLine = mtext.split(separator: "\n").first(where: { $0.contains("URI=\"") }),
               let r = audioLine.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let inner = audioLine[r].dropFirst(5).dropLast()
                if let au = URL(string: String(inner)) {
                    let (adata, aresp) = try await get(au)
                    let atext = String(decoding: adata, as: UTF8.self)
                    let seg = atext.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.isEmpty }
                    print("   音频轨 playlist → \(aresp.statusCode) \(adata.count)B，改写包含 /p?u=：\(atext.contains("/p?u="))")
                    if let seg, let su = URL(string: String(seg), relativeTo: au) {
                        let (sdata, sresp) = try await get(su.absoluteURL)
                        print("   音频分片 → \(sresp.statusCode) \(sdata.count)B 首字节 0x\(String(sdata.first ?? 0, radix: 16)) \(sdata.first == 0x47 ? "✓" : "✗")")
                    }
                }
            }
            print("✅ HLS 链路 OK（master 合成 + URI 改写 + 分片反代全部可用）")
        }
    }
}
