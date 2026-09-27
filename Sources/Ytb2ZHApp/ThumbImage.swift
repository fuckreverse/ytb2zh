import SwiftUI
import AppKit
import Ytb2ZHEngines

/// 代理感知的远程图片：AsyncImage 走系统 URLSession（不走 app 全局代理），
/// 在需要代理的网络下会一直占位；这里用 connectionProxyDictionary 显式走配置代理。
struct ThumbImage: View {
    let url: String?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
            } else {
                Rectangle().fill(.quinary)
                    .overlay(ProgressView().controlSize(.small).opacity(failed ? 0 : 1))
                    .overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: url) {
            guard let url, !url.isEmpty, let u = URL(string: url) else { failed = true; return }
            if let url = URL(string: url), let cached = ThumbCache.shared.object(forKey: url as NSURL) { image = cached; return }
            let cfg = URLSessionConfiguration.default
            let proxy = AppSettings.effectiveProxy(fallback: "")
            if !proxy.isEmpty, let purl = URL(string: proxy), let host = purl.host, let port = purl.port {
                cfg.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: true,
                    kCFNetworkProxiesHTTPProxy as String: host,
                    kCFNetworkProxiesHTTPPort as String: port,
                    "HTTPSEnable": true,
                    "HTTPSProxy": host,
                    "HTTPSPort": port,
                ]
            }
            cfg.timeoutIntervalForRequest = 15
            do {
                let (data, resp) = try await URLSession(configuration: cfg).data(from: u)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let img = NSImage(data: data) else { failed = true; return }
                if let u = URL(string: url) { ThumbCache.shared.setObject(img, forKey: u as NSURL) }
                image = img
            } catch {
                failed = true
            }
        }
    }
}

enum ThumbCache {
    nonisolated(unsafe) static let shared = NSCache<NSURL, NSImage>()
}

extension CatalogVideo {
    /// 观看数文案（无尾随 .0）
    var viewCountText: String? {
        guard let v = viewCount, v > 0 else { return nil }
        if v >= 10_000_000 { return Self.trimNum(Double(v) / 10_000_000) + " 千万次观看" }
        if v >= 10_000 { return Self.trimNum(Double(v) / 10_000) + " 万次观看" }
        return "\(v) 次观看"
    }

    private static func trimNum(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}
