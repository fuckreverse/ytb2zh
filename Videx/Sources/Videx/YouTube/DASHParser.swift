import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Native MPD parsing with inherited BaseURL, SegmentBase/List/Template and timelines.
enum DASHParser {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
    }
    final class Reader: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let node = Node(name.components(separatedBy: ":").last ?? name, attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    }

    static func duration(_ value: String?) -> Double? {
        guard let value, RegexKit.firstMatch(pattern: #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#, in: value) != nil else { return nil }
        // Optional capture groups are compacted by RegexKit; parse each unit independently.
        return [("D",86400.0),("H",3600.0),("M",60.0),("S",1.0)].reduce(0) { sum, unit in
            sum + ((RegexKit.firstMatch(pattern: "([0-9.]+)" + unit.0, in: value)?[1]).flatMap(Double.init) ?? 0) * unit.1
        }
    }

    static func formats(_ data: Data, url: URL) throws -> [MediaFormat] {
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root, root.name == "MPD" else { throw ExtractionError.parse("无效 DASH MPD") }
        let live = root.attributes["type"] == "dynamic"
        var formats: [MediaFormat] = []
        func base(_ node: Node, _ parent: URL) -> URL {
            guard let value = node.child("BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, let resolved = URL(string: value, relativeTo: parent)?.absoluteURL else { return parent }
            return resolved
        }
        for period in root.children where period.name == "Period" {
            let periodBase = base(period, base(root, url))
            let seconds = duration(period.attributes["duration"]) ?? duration(root.attributes["mediaPresentationDuration"])
            let clock = date(root.attributes["publishTime"]) ?? Date()
            let liveEnd = date(root.attributes["availabilityStartTime"]).map { max(0, clock.timeIntervalSince($0) - (duration(period.attributes["start"]) ?? 0)) }
            for adaptation in period.children where adaptation.name == "AdaptationSet" {
                for representation in adaptation.children where representation.name == "Representation" {
                    let chain = [root, period, adaptation, representation]
                    if chain.contains(where: { $0.child("ContentProtection") != nil }) { continue }
                    let attributes = chain.reduce([String: String]()) { $0.merging($1.attributes) { _, new in new } }
                    let repBase = base(representation, base(adaptation, periodBase))
                    let id = attributes["id"] ?? String(formats.count)
                    let mime = attributes["mimeType"] ?? ""
                    let type = attributes["contentType"] ?? mime.components(separatedBy: "/").first ?? ""
                    let kind: MediaKind = type == "audio" ? .audioOnly : .videoOnly
                    let codec = attributes["codecs"]
                    let templateNodes = chain.compactMap { $0.child("SegmentTemplate") }
                    let templates = templateNodes.reduce([String: String]()) { $0.merging($1.attributes) { _, new in new } }
                    let timeline = templateNodes.reversed().compactMap { $0.child("SegmentTimeline") }.first
                    var fragments: [MediaFragment] = []
                    func resolve(_ path: String) -> URL? {
                        guard let value = URL(string: path, relativeTo: repBase)?.absoluteURL,
                              ["https", "http"].contains(value.scheme ?? "") else { return nil }
                        return value
                    }
                    if let list = chain.reversed().compactMap({ $0.child("SegmentList") }).first {
                        if let initNode = list.child("Initialization"), let initURL = resolve(initNode.attributes["sourceURL"] ?? "") {
                            fragments.append(MediaFragment(url: initURL, byteRange: initNode.attributes["range"], isInitialization: true))
                        }
                        let scale = Double(list.attributes["timescale"] ?? "1") ?? 1
                        for (segmentIndex, segment) in list.children.filter({ $0.name == "SegmentURL" }).enumerated() {
                            if let media = segment.attributes["media"], let segmentURL = resolve(media) {
                                fragments.append(MediaFragment(url: segmentURL, duration: Double(list.attributes["duration"] ?? "").map { $0 / max(1, scale) }, byteRange: segment.attributes["mediaRange"], sequence: Int64(segmentIndex) + (list.attributes["startNumber"].flatMap(Int64.init) ?? 1)))
                            }
                        }
                    } else if let media = templates["media"] {
                        let scale = max(1, Int64(templates["timescale"] ?? "1") ?? 1)
                        var number = Int64(templates["startNumber"] ?? "1") ?? 1
                        var time = Int64(templates["presentationTimeOffset"] ?? "0") ?? 0
                        if let initialization = templates["initialization"], let initURL = resolve(expand(initialization, id: id, bandwidth: attributes["bandwidth"] ?? "0", number: number, time: time)) {
                            fragments.append(MediaFragment(url: initURL, isInitialization: true))
                        }
                        func append(_ ticks: Int64) {
                            if let segmentURL = resolve(expand(media, id: id, bandwidth: attributes["bandwidth"] ?? "0", number: number, time: time)) {
                                fragments.append(MediaFragment(url: segmentURL, duration: Double(ticks) / Double(scale), sequence: number))
                            }
                            number += 1; time += ticks
                        }
                        if let timeline {
                            let entries = timeline.children.filter { $0.name == "S" }
                            for (index, entry) in entries.enumerated() {
                                guard let ticks = entry.attributes["d"].flatMap(Int64.init), ticks > 0 else { continue }
                                time = entry.attributes["t"].flatMap(Int64.init) ?? time
                                var repeatCount = entry.attributes["r"].flatMap(Int.init) ?? 0
                                if repeatCount < 0 {
                                    let bound = entries.dropFirst(index + 1).first?.attributes["t"].flatMap(Int64.init)
                                        ?? (seconds ?? liveEnd).map { Int64($0 * Double(scale)) + (templates["presentationTimeOffset"].flatMap(Int64.init) ?? 0) }
                                    guard let bound else { continue }
                                    repeatCount = max(0, Int((bound - time + ticks - 1) / ticks) - 1)
                                }
                                guard repeatCount < 100000, fragments.count + repeatCount < 100000 else { throw ExtractionError.parse("DASH 分片时间轴超出限制") }
                                for _ in 0...repeatCount { append(ticks) }
                            }
                        } else if let ticks = templates["duration"].flatMap(Int64.init), ticks > 0, live, let liveEnd {
                            let endIndex = Int64(floor(liveEnd * Double(scale) / Double(ticks)))
                            let window = duration(root.attributes["timeShiftBufferDepth"]) ?? 30
                            let count = min(100000, max(1, Int64(ceil(window * Double(scale) / Double(ticks)))))
                            let first = max(0, endIndex - count)
                            number += first; time += first * ticks
                            if endIndex > first { for _ in first..<endIndex { append(ticks) } }
                        } else if let ticks = templates["duration"].flatMap(Int64.init), ticks > 0, let seconds, !live {
                            let count = Int(ceil(seconds * Double(scale) / Double(ticks)))
                            guard count <= 100000 else { throw ExtractionError.parse("DASH 分片数超出限制") }
                            for _ in 0..<max(0, count) { append(ticks) }
                        }
                    }
                    let hasSegments = chain.contains { $0.child("SegmentTemplate") != nil || $0.child("SegmentList") != nil }
                    guard !hasSegments || fragments.contains(where: { !$0.isInitialization }) else { continue }
                    let formatURL = hasSegments ? url : repBase
                    guard ["http", "https"].contains(formatURL.scheme ?? ""), hasSegments || formatURL != url else { continue }
                    formats.append(MediaFormat(formatID: id + (hasSegments ? "-dash" : ""), kind: kind,
                        url: formatURL, container: mime.contains("webm") ? "webm" : "mp4",
                        videoCodec: kind == .videoOnly ? codec : nil, audioCodec: kind == .audioOnly ? codec : nil,
                        width: attributes["width"].flatMap(Int.init), height: attributes["height"].flatMap(Int.init),
                        fps: frameRate(attributes["frameRate"]), averageBitrate: attributes["bandwidth"].flatMap(Int.init),
                        protocolType: hasSegments ? .dash : .https, language: attributes["lang"],
                        fragments: hasSegments ? fragments : nil, manifestURL: url, representationID: id,
                        isLive: live))
                }
            }
        }
        return formats
    }

    static func expand(_ template: String, id: String, bandwidth: String, number: Int64, time: Int64) -> String {
        var value = template.replacingOccurrences(of: "$$", with: "\u{1}")
        value = value.replacingOccurrences(of: "$RepresentationID$", with: id).replacingOccurrences(of: "$Bandwidth$", with: bandwidth)
        for (key, numeric) in [("Number", number), ("Time", time)] {
            let pattern = "\\$" + key + "(?:%0([0-9]+)d)?\\$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                let width = Range(match.range(at: 1), in: value).flatMap { Int(value[$0]) } ?? 0
                let replacement = String(repeating: "0", count: max(0, min(20, width) - String(numeric).count)) + String(numeric)
                value.replaceSubrange(range, with: replacement)
            }
        }
        return value.replacingOccurrences(of: "\u{1}", with: "$")
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func frameRate(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: "/").compactMap { Double($0) }
        guard let first = parts.first else { return nil }
        return Int((parts.count == 2 && parts[1] > 0 ? first / parts[1] : first).rounded())
    }
}
