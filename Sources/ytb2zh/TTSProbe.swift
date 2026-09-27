import Foundation
import Ytb2ZHCore
import Ytb2ZHEngines

// 隐藏子命令：tts-probe <text> —— 直接探测百炼 WS 协议
enum TTSProbe {
    static func run(_ args: [String]) async throws {
        let text = args.isEmpty ? "你好，世界。" : args.joined()
        print("连接 \(SynthOptions().wsURL) …")
        do {
            let audio = try await BailianSynthEngine.synthesizeWS(text: text, options: SynthOptions())
            let out = URL(fileURLWithPath: "/tmp/ytb2zh_tts_probe.mp3")
            try? FileManager.default.removeItem(at: out)
            try audio.write(to: out)
            print("收到 \(audio.count) 字节 → \(out.path)")
        } catch {
            print("失败：\(error)")
            throw error
        }
    }
}
