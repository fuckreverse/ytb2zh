import Foundation
import Videx

extension VidexCLI {
    static func download(info: MediaInfo, url: URL, registry: ExtractorRegistry, options: ExtractionOptions,
                         expression: String, directory: URL, start: Double, duration: Double?, liveFromStart: Bool) async throws -> URL {
        let selections = try FormatSelector.select(info, expression: expression)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (group, selection) in selections.enumerated() {
            let work = directory.appendingPathComponent(".\(info.id)-\(group)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let indexedInputs: [(Int, URL)] = try await withThrowingTaskGroup(of: (Int, URL).self) { taskGroup in
                for (index, format) in selection.formats.enumerated() {
                    let input = work.appendingPathComponent("\(index).\(format.container ?? "mp4")")
                    let refresh: @Sendable () async throws -> MediaFormat = {
                        let fresh = try await registry.extract(url: url, options: options)
                        guard let result = fresh.formats.first(where: { $0.formatID == format.formatID && $0.audioTrackID == format.audioTrackID }) else {
                            throw ExtractionError.notExtractable(site: "youtube", reason: "刷新后原格式不可用")
                        }
                        return result
                    }
                    taskGroup.addTask {
                        let http = URLSessionHTTPClient(proxy: options.proxy)
                        if format.protocolType == .sabr {
                            _ = try await SABRDownloader.download(format: format, to: input, http: http,
                                options: SABRDownloadOptions(startSeconds: start, durationSeconds: duration, liveFromStart: liveFromStart), refresh: refresh)
                        } else if format.protocolType == .hls {
                            _ = try await NativeHLSDownloader.download(format: format, to: input, http: http,
                                refresh: refresh, durationSeconds: duration.map { $0 + start }, liveFromStart: liveFromStart)
                        } else {
                            _ = try await NativeMediaDownloader.download(format: format, to: input, http: http,
                                refresh: refresh, partialSeconds: duration.map { $0 + start }, liveFromStart: liveFromStart)
                        }
                        return (index, input)
                    }
                }
                var collected: [(Int, URL)] = []
                for try await pair in taskGroup {
                    collected.append(pair)
                }
                return collected.sorted { $0.0 < $1.0 }
            }
            let inputs = indexedInputs.map(\.1)
            // Existing ffmpeg is used only as a container muxer; extraction/streaming remain Swift/JSC.
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/ffmpeg" }
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw ExtractionError.notExtractable(site: "videx", reason: "原生媒体已下载，封装需要现有 ffmpeg；分离流保留于 \(work.path)")
            }
            let ext = selection.formats.first?.container == "webm" ? "mkv" : "mp4"
            let output = directory.appendingPathComponent(info.id + (selections.count > 1 ? "-\(group)" : "") + "." + ext)
            let temporary = directory.appendingPathComponent(".\(output.lastPathComponent).remux.\(ext)")
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            var args = ["-y", "-loglevel", "error"]
            for input in inputs { args += ["-i", input.path] }
            for (index, format) in selection.formats.enumerated() {
                if format.kind != .audioOnly { args += ["-map", "\(index):v:0?"] }
                if format.kind != .videoOnly { args += ["-map", "\(index):a:0?"] }
            }
            if start > 0 && !selection.formats.contains(where: { $0.protocolType == .sabr }) { args += ["-ss", String(start)] }
            if let duration { args += ["-t", String(duration)] }
            args += ["-c", "copy", temporary.path]
            process.arguments = args
            process.standardOutput = FileHandle.standardError; process.standardError = FileHandle.standardError
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ExtractionError.parse("媒体封装失败，分离文件保留") }
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try FileManager.default.moveItem(at: temporary, to: output)
            try? FileManager.default.removeItem(at: work)
            outputs.append(output)
            FileHandle.standardError.write(Data("已保存 \(output.path)\n".utf8))
        }
        guard let result = outputs.first else { throw ExtractionError.parse("没有下载结果") }
        return result
    }
}
