import Foundation

// MARK: - 子进程执行助手（所有 sidecar 引擎共用）

public struct ProcessRunner: Sendable {
    public init() {}

    @discardableResult
    public func run(_ launchPath: String, _ args: [String],
                    cwd: URL? = nil,
                    env: [String: String]? = nil,
                    onStdout: (@Sendable (String) -> Void)? = nil,
                    onStderr: (@Sendable (String) -> Void)? = nil) throws -> (code: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let stdoutBox = Mutex("")
        let stderrBox = Mutex("")

        func attach(_ handle: FileHandle, _ sink: (@Sendable (String) -> Void)?, _ box: Mutex<String>) {
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                box.with { $0 += s }
                sink?(s)
            }
        }
        attach(outPipe.fileHandleForReading, onStdout, stdoutBox)
        attach(errPipe.fileHandleForReading, onStderr, stderrBox)

        try p.run()
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // 兜底读余量
        let rest1 = outPipe.fileHandleForReading.readDataToEndOfFile()
        let rest2 = errPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutBox.with { $0 += String(data: rest1, encoding: .utf8) ?? "" }
        stderrBox.with { $0 += String(data: rest2, encoding: .utf8) ?? "" }
        return (p.terminationStatus, stdoutBox.wrapped, stderrBox.wrapped)
    }

    /// 带超时的进程执行（超时 kill）
    @discardableResult
    public func runWithTimeout(_ seconds: TimeInterval, _ launchPath: String, _ args: [String],
                               cwd: URL? = nil, env: [String: String]? = nil) throws -> (code: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }
}

public enum SidecarPaths {
    /// yt-dlp：仅按需安装的缓存目录，或 PATH（默认不捆绑；由 YtDlpInstaller 负责下载）
    public static var ytDlp: String {
        let cached = NSHomeDirectory() + "/.ytb2zh/bin/yt-dlp_macos"
        if FileManager.default.isExecutableFile(atPath: cached) { return cached }
        return which("yt-dlp") ?? "yt-dlp"
    }

    public static var whisperCli: String {
        which("whisper-cli") ?? "/opt/homebrew/opt/whisper.cpp/bin/whisper-cli" ?? "whisper-cli"
    }

    public static var ffmpeg: String { which("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg" }

    public static func which(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":").map(String.init)
        for dir in paths where FileManager.default.isExecutableFile(atPath: dir + "/" + name) {
            return dir + "/" + name
        }
        return nil
    }
}
