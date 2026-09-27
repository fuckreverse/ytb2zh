import Foundation
import Ytb2ZHCore

// MARK: - 引擎装配：注册所有可用插件，按 Profile 解析出 EngineSet
// 新增引擎 = 实现协议 + 在 registry() 注册一行 + engineSet() 里按 id 挑选。

public enum EngineAssembly {
    public static func registry() -> EngineRegistry {
        EngineRegistry([
            .init(step: .download, descriptors: [
                SmartDownloadEngine().descriptor, YtDlpDownloadEngine().descriptor, FileImportEngine().descriptor]),
            .init(step: .separate, descriptors: [
                NullVocalSeparator().descriptor, DemucsVocalSeparator().descriptor]),
            .init(step: .transcribe, descriptors: [
                WhisperCliEngine().descriptor, SrtTranscribeEngine().descriptor]),
            .init(step: .segment, descriptors: [
                PunctSegmentationEngine().descriptor, LLMSegmentationEngine().descriptor]),
            .init(step: .summarize, descriptors: [
                NullTerminologyEngine().descriptor, GatewayTerminologyEngine().descriptor]),
            .init(step: .translate, descriptors: [
                GatewayTranslateEngine().descriptor, OpenAICompatTranslateEngine().descriptor]),
            .init(step: .synthesize, descriptors: [
                BailianSynthEngine().descriptor, OpenAITTSEngine().descriptor,
                EdgeTTSEngine().descriptor, LocalSayTTSEngine().descriptor,
                SherpaOnnxTTSEngine().descriptor, NullSynthEngine().descriptor]),
            .init(step: .schedule, descriptors: [
                DriftSchedulerEngine().descriptor, NullSchedulerEngine().descriptor]),
            .init(step: .compose, descriptors: [FFmpegComposeEngine().descriptor]),
        ])
    }

    public static func engineSet(for profile: Profile) throws -> EngineSet {
        let errors = registry().validate(profile: profile)
        guard errors.isEmpty else { throw EngineError.notConfigured(errors.joined(separator: "；")) }

        func id(_ step: StepID, _ fallback: String) -> String {
            profile.engines[step.rawValue] ?? fallback
        }

        let downloader: any DownloadEngine = {
            switch id(.download, "yt-dlp") {
            case "auto": SmartDownloadEngine()
            case "file": FileImportEngine()
            default: YtDlpDownloadEngine()
            }
        }()
        let separator: (any VocalSeparationEngine)? = id(.separate, "none") == "demucs" ? DemucsVocalSeparator() : nil
        let transcriber: any TranscribeEngine = id(.transcribe, "whisper-cpp") == "srt" ? SrtTranscribeEngine() : WhisperCliEngine()
        let segmenter: any SegmentationEngine = id(.segment, "punct") == "llm-seg" ? LLMSegmentationEngine() : PunctSegmentationEngine()
        let terminologist: (any TerminologyEngine)? = id(.summarize, "none") == "gateway-terms" ? GatewayTerminologyEngine() : nil
        let translator: any TranslateEngine = id(.translate, "gateway") == "compat" ? OpenAICompatTranslateEngine() : GatewayTranslateEngine()
        let synthesizer: any SpeechSynthesisEngine = {
            switch id(.synthesize, "bailian") {
            case "openai-tts": OpenAITTSEngine()
            case "edge-tts": EdgeTTSEngine()
            case "local-say": LocalSayTTSEngine()
            case "sherpa-onnx": SherpaOnnxTTSEngine()
            case "none": NullSynthEngine()
            default: BailianSynthEngine()
            }
        }()
        let scheduler: any SchedulerEngine = id(.schedule, "drift") == "none" ? NullSchedulerEngine() : DriftSchedulerEngine()

        return EngineSet(
            downloader: downloader, transcriber: transcriber, segmenter: segmenter,
            translator: translator, synthesizer: synthesizer, scheduler: scheduler,
            composer: FFmpegComposeEngine(),
            separator: separator, terminologist: terminologist)
    }
}
