import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 引擎选择行（每步一个 Picker，数据来自 EngineRegistry）

struct EnginePickerRow: View {
    @Binding var profile: Profile
    private let registry = EngineAssembly.registry()

    var body: some View {
        CinemaSection("引擎（可插拔）") {
            ForEach(registry.offers, id: \.step) { offer in
                LabeledContent(L(offer.step.label)) {
                    CinemaSelect(offer.step.label, selection: binding(for: offer.step), options: offer.descriptors.map { CinemaOption($0.id, $0.name) })
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    private func binding(for step: StepID) -> Binding<String> {
        Binding(
            get: { profile.engines[step.rawValue] ?? "" },
            set: { profile.engines[step.rawValue] = $0 })
    }
}

// MARK: - 参数面板（常用参数平铺；高级参数折叠；合成参数随所选引擎联动）

struct ParameterPanel: View {
    @Binding var profile: Profile
    @State private var advancedExpanded = false

    /// 当前语音合成引擎 id（未设置时取默认 bailian）
    private var synthEngineID: String {
        profile.engines[StepID.synthesize.rawValue] ?? "bailian"
    }

    private var transcribeEngineID: String {
        profile.engines[StepID.transcribe.rawValue] ?? "whisper-native"
    }

    private var composeEngineID: String {
        profile.engines[StepID.compose.rawValue] ?? "ffmpeg"
    }

    var body: some View {
        CinemaSection("配音音色") {
            synthEngineParams
            if synthEngineID != "none" {
                sliderRow("合成语速", value: $profile.synth.rate,
                          in: SynthOptions.rateMin...SynthOptions.rateMax, step: 0.05,
                          hint: "1.00 = 原始速度；支持原生变速的引擎直接以该语速合成，其余由对齐层微调兑现")
            }
        }

        CinemaSection("翻译效果") {
            LabeledContent("风格") {
                CinemaSelect("风格", selection: $profile.translate.style, options: TranslationStyle.allCases.map { CinemaOption($0, L10n.tr($0.label)) })
                .labelsHidden()
                .frame(width: 220)
            }
            LabeledContent("质量") {
                CinemaSelect("质量", selection: $profile.translate.quality, options: TranslationQuality.allCases.map { CinemaOption($0, L10n.tr($0.label)) })
                .labelsHidden()
                .frame(width: 220)
            }
            LabeledContent("目标语言") {
                CinemaSelect("目标语言", selection: $profile.translate.targetLanguage, options: [CinemaOption("zh", L10n.tr("中文")), CinemaOption("en", L10n.tr("English")), CinemaOption("ja", L10n.tr("日本語")), CinemaOption("ko", L10n.tr("한국어"))])
                .labelsHidden()
                .frame(width: 220)
            }
            Toggle("启用术语表（翻译前提取/人工修订）", isOn: $profile.translate.useTerminology)

        }

        CinemaSection("字幕与声音") {
            Toggle("中英双语字幕", isOn: $profile.compose.bilingualSubtitles)
            if composeEngineID != "sidecar" {
                Toggle("保留背景音乐（需开启人声分离）", isOn: $profile.compose.keepBGM)
                Toggle("保留原声并降低音量", isOn: $profile.compose.keepOriginalAudio)
            }
        }

        CinemaSection {
            CinemaDisclosure(isExpanded: $advancedExpanded) {
                EnginePickerRow(profile: $profile)
                groupHeader("本地语音识别（ASR）调优")
                if transcribeEngineID == "whisper-native" || transcribeEngineID == "whisper-cpp" {
                    LabeledContent("Whisper 模型") {
                        CinemaSelect("Whisper 模型", selection: whisperPresetBinding, options: [
                            CinemaOption("ggml-large-v3-turbo-q5_0.bin", L10n.tr("Large-v3-Turbo Q5（推荐·547MB 高准度）")),
                            CinemaOption("ggml-base.en", L10n.tr("Base.en（轻量·142MB 极速）")),
                            CinemaOption("ggml-medium.en-q5_0.bin", L10n.tr("Medium.en Q5（均衡）")),
                            CinemaOption("ggml-large-v3-turbo.bin", L10n.tr("Large-v3-Turbo FP16（完整精度·1.5GB）")),
                        ])
                        .labelsHidden()
                        .frame(width: 280)
                    }
                    Toggle("DTW 毫秒级词时间戳精确对齐（消除长停顿漂移）", isOn: $profile.transcribe.enableDTW)
                } else if transcribeEngineID == "sherpa-asr" {
                    LabeledContent("离线识别模型") {
                        CinemaSelect("离线识别模型", selection: sherpaASRPresetBinding, options: [
                            CinemaOption("parakeet", L10n.tr("Parakeet TDT 0.6B v3（英文极速王·640MB）")),
                            CinemaOption("sensevoice", L10n.tr("SenseVoice 多语种识别（中英日韩粤）")),
                            CinemaOption("qwen3-asr", L10n.tr("Qwen3-ASR 0.6B（专有名词强）")),
                        ])
                        .labelsHidden()
                        .frame(width: 280)
                    }
                }
                groupHeader("处理速度与翻译细节")
                Toggle("自动扩译（填不满时间窗时扩写）", isOn: $profile.translate.autoExpand)
                Toggle("自动缩译（超出时间窗时精简防赶拍）", isOn: $profile.translate.autoCompress)
                Toggle("中文播客长句连读模式（减少逗号碎切，保留整句呼吸与语调起伏）", isOn: $profile.synth.podcastMode)
                sliderRow("目标音节速率", value: $profile.translate.targetSyllablesPerSec, in: 3.0...6.0, step: 0.1,
                          hint: "每秒目标音节/汉字数（供 Index-Homura 音节受控翻译使用，默认 4.2）")
                stepperRow("批次大小", value: $profile.translate.batchSize, in: 4...40, hint: "每批翻译条数")
                stepperRow("并发批次", value: $profile.translate.concurrency, in: 1...8, hint: "")
                stepperRow("配音并发", value: $profile.synth.rps, in: 1...5, hint: "根据服务限流调整")
                groupHeader("对齐调度（音画同步手感）")
                sliderRow("漂移上限", value: $profile.schedule.driftCap, in: 0.5...3.0, step: 0.1,
                          hint: "配音最多领先画面（秒）")
                sliderRow("落后上限", value: $profile.schedule.lagCap, in: 0.2...2.0, step: 0.1,
                          hint: "配音最多落后画面（秒）")
                sliderRow("句间停顿上限", value: $profile.schedule.pauseMax, in: 0.5...2.0, step: 0.1,
                          hint: "子句间最多扩到多少秒停顿")
                sliderRow("最小停顿", value: $profile.schedule.pauseMin, in: 0.1...0.6, step: 0.05,
                          hint: "子句间停顿下限")
                sliderRow("慢放上限", value: $profile.schedule.slowMax, in: 1.0...1.25, step: 0.01,
                          hint: "1.15 = 语音最多拉慢 15%")
                sliderRow("加速上限", value: $profile.schedule.fastMax, in: 1.0...1.6, step: 0.05,
                          hint: "溢出时最多加速倍率")

                groupHeader("语义切分")
                sliderRow("软收句窗口", value: $profile.segmentation.softWindow, in: 4...10, step: 0.5,
                          hint: "逗号处累计多少秒可收句")
                sliderRow("强制收句", value: $profile.segmentation.hardWindow, in: 8...20, step: 0.5,
                          hint: "超过即强制切分")

                groupHeader("视频合成")
                if composeEngineID == "sidecar" {
                    Text("旁挂字幕模式：字幕不烧录、视频不重编码，以下仅保留影响 SRT 文本的参数")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if composeEngineID != "sidecar" {
                    sliderRow("字幕字号", value: $profile.compose.subtitleFontSize, in: 10...28, step: 1, hint: "")
                    sliderRow("字幕底边距", value: $profile.compose.subtitleMarginV, in: 10...80, step: 2, hint: "")
                }
                sliderRow("单行字数上限", value: Binding(
                    get: { Double(profile.compose.subtitleMaxLength) },
                    set: { profile.compose.subtitleMaxLength = Int($0) }),
                    in: 16...90, step: 1, hint: "Netflix 标准：超长行自动二次拆分")
                sliderRow("行长偏置", value: $profile.compose.subtitleTargetMultiplier, in: 1.0...2.0, step: 0.1,
                          hint: "1.2 = 预期行长 = 上限/1.2，越大切得越碎")
                if composeEngineID != "sidecar" {
                    sliderRow("配音增益", value: $profile.compose.dubGainDB, in: 0...10, step: 0.5, hint: "dB")
                    sliderRow("BGM 增益", value: $profile.compose.bgmGainDB, in: -12...3, step: 0.5,
                              hint: "dB，负值压低伴奏")
                    stepperRow("CRF", value: $profile.compose.crf, in: 14...30, hint: "越小越清晰越大")
                }
            } label: {
                Text("高级参数 · 引擎、处理速度与字幕微调")
                    .foregroundStyle(advancedExpanded ? Color.accentColor : .primary)
            }
        } header: {
            Text("高级设置 · 默认参数适合大多数视频")
        }
    }

    // MARK: 合成参数随引擎联动：只显示当前引擎需要的参数，避免“改了也不生效”的误导

    @ViewBuilder
    private var synthEngineParams: some View {
        switch synthEngineID {
        case "edge-tts":
            LabeledContent("Edge TTS 音色") {
                CinemaSelect("Edge TTS 音色", selection: $profile.synth.edgeVoice, options: [CinemaOption("zh-CN-YunxiNeural", L10n.tr("云希（年轻男声）")), CinemaOption("zh-CN-XiaoxiaoNeural", L10n.tr("晓晓（女声）")), CinemaOption("zh-CN-YunyeNeural", L10n.tr("云野（男声）")), CinemaOption("zh-CN-XiaoyiNeural", L10n.tr("晓伊（女声）"))])
                .labelsHidden()
                .frame(width: 220)
            }
        case "local-say":
            LabeledContent("本地 say 音色") {
                CinemaSelect("本地音色", selection: $profile.synth.localVoice, options: [CinemaOption("Tingting", L10n.tr("婷婷（经典女声）")), CinemaOption("Bobo (Enhanced)", L10n.tr("波波（增强女声）")), CinemaOption("Eddy (中文（中国大陆）)", L10n.tr("Eddy（男声）")), CinemaOption("Flo (中文（中国大陆）)", L10n.tr("Flo（女声）")), CinemaOption("Rocko (中文（中国大陆）)", L10n.tr("Rocko（男声）")), CinemaOption("Shelley (中文（中国大陆）)", L10n.tr("Shelley（女声）"))])
                .labelsHidden()
                .frame(width: 220)
                .help("macOS 系统语音，离线可用；更多音色在系统设置 → 辅助功能 → 朗读内容安装")
            }
        case "sherpa-onnx":
            LabeledContent("离线语音方案") {
                CinemaSelect("离线语音方案", selection: sherpaModelBinding, options: [
                    CinemaOption("kokoro-multi-lang-v1_1", L10n.tr("Kokoro 中英混读播客（推荐·自动下载）")),
                    CinemaOption("zipvoice", L10n.tr("ZipVoice 零样本原声复刻（自动克隆博主声音）")),
                    CinemaOption("vits-zh-hf-theresa", L10n.tr("Theresa 经典中文女声（轻量·170MB）")),
                ])
                .labelsHidden()
                .frame(width: 280)
            }
            if sherpaModelBinding.wrappedValue == "zipvoice" {
                Text("已启用零样本原声复刻：将自动从视频中截取 5~8 秒最清晰的博主原声说中文，无需手动切片")
                    .font(.caption).foregroundStyle(.secondary)
            } else if sherpaModelBinding.wrappedValue == "kokoro-multi-lang-v1_1" {
                LabeledContent("播客主播音色") {
                    CinemaSelect("播客主播音色", selection: kokoroVoiceBinding, options: [
                        CinemaOption("zm_010", L10n.tr("云希 · 沉稳科技男播客")),
                        CinemaOption("zm_009", L10n.tr("云健 · 磁性深沉男声")),
                        CinemaOption("zm_011", L10n.tr("云夏 · 活力少年男声")),
                        CinemaOption("zm_012", L10n.tr("云扬 · 专业叙事男声")),
                        CinemaOption("zf_001", L10n.tr("晓北 · 亲切自然女播客")),
                        CinemaOption("zf_002", L10n.tr("晓妮 · 温柔知性女声")),
                        CinemaOption("zf_003", L10n.tr("晓晓 · 清脆活力女声")),
                        CinemaOption("zf_004", L10n.tr("晓伊 · 甜美讲述女声")),
                        CinemaOption("af_heart", L10n.tr("Heart · 美式自然女声")),
                        CinemaOption("am_adam", L10n.tr("Adam · 美式沉稳男声")),
                    ])
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
        case "mlx-tts":
            LabeledContent("MLX 播客模型") {
                CinemaSelect("MLX 播客模型", selection: mlxModelBinding, options: [
                    CinemaOption("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", L10n.tr("Qwen3-TTS 0.6B 极速播客版（推荐）")),
                    CinemaOption("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", L10n.tr("Qwen3-TTS 1.7B 情感精修版")),
                    CinemaOption("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", L10n.tr("Qwen3-TTS 1.7B 自然语言捏音色")),
                    CinemaOption("OpenMOSS-Team/MOSS-TTSD-v1.0", L10n.tr("MOSS-TTSD 1.0 双人播客对话版")),
                ])
                .labelsHidden()
                .frame(width: 280)
            }
            LabeledContent("播客主播音色") {
                CinemaSelect("播客主播音色", selection: mlxVoicePresetBinding, options: [
                    CinemaOption("Dylan", L10n.tr("Dylan · 沉稳科技男主播")),
                    CinemaOption("Vivian", L10n.tr("Vivian · 知性自然女主播")),
                    CinemaOption("Uncle_Fu", L10n.tr("Uncle_Fu · 醇厚故事男声")),
                    CinemaOption("Serena", L10n.tr("Serena · 温柔亲切女声")),
                    CinemaOption("Eric", L10n.tr("Eric · 阳光活力男声")),
                ])
                .labelsHidden()
                .frame(width: 240)
            }
            Toggle("零样本复刻原视频博主音色（自动截取 5~8s 清晰人声）", isOn: $profile.synth.cloneSourceVoice)
        case "openai-tts":
            Text("音色/模型在「应用设置 → 模型提供商」按能力配置")
                .font(.callout).foregroundStyle(.secondary)
        case "none":
            Text("当前模板不配音（仅字幕）；可在下方「高级参数 → 语音合成」选择配音方式")
                .font(.callout).foregroundStyle(.secondary)
        default:
            // bailian（默认）：百炼音色 + 并发
            LabeledContent("音色") {
                CinemaSelect("音色", selection: $profile.synth.voice, options: [CinemaOption("anmingyuan_v3.1", L10n.tr("安明远（沉稳男声）")), CinemaOption("huozhuoshi_v3.1", L10n.tr("火烛时（开朗男声）")), CinemaOption("longsanshu_v3.1", L10n.tr("龙三叔（东北男声）")), CinemaOption("xuyanchu_v3.1", L10n.tr("许言初（儒雅男声）")), CinemaOption("yuxiaoyun_v3.1", L10n.tr("于晓云（知性女声）")), CinemaOption("qingge_v3.2", L10n.tr("清歌（温柔女声）"))])
                .labelsHidden()
                .frame(width: 220)
            }

        }
    }

    private func groupHeader(_ label: String) -> some View {
        Text(label)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: - 人性化预设绑定（将底层模型路径/代号归一化为下拉菜单友好项）

    private var whisperPresetBinding: Binding<String> {
        Binding(
            get: {
                let raw = profile.transcribe.modelPath.trimmingCharacters(in: .whitespaces)
                if raw.contains("large-v3-turbo-q5_0") { return "ggml-large-v3-turbo-q5_0.bin" }
                if raw.contains("large-v3-turbo") { return "ggml-large-v3-turbo.bin" }
                if raw.contains("medium.en") && !raw.contains("/vid2zh/") { return "ggml-medium.en-q5_0.bin" }
                return "ggml-base.en"
            },
            set: { profile.transcribe.modelPath = $0 }
        )
    }

    private var sherpaASRPresetBinding: Binding<String> {
        Binding(
            get: {
                let raw = profile.transcribe.sherpaModelDir.lowercased()
                if raw.contains("sense") { return "sensevoice" }
                if raw.contains("qwen") { return "qwen3-asr" }
                return "parakeet"
            },
            set: { profile.transcribe.sherpaModelDir = $0 }
        )
    }

    private var sherpaModelBinding: Binding<String> {
        Binding(
            get: {
                let raw = profile.synth.sherpaOnnxModelDir.lowercased()
                if raw.contains("zipvoice") { return "zipvoice" }
                if raw.contains("kokoro") { return "kokoro-multi-lang-v1_1" }
                if raw.isEmpty { return "kokoro-multi-lang-v1_1" }
                return "vits-zh-hf-theresa"
            },
            set: { newVal in
                profile.synth.sherpaOnnxModelDir = newVal
                if newVal == "zipvoice" {
                    profile.synth.cloneSourceVoice = true
                    profile.synth.podcastMode = true
                } else if newVal.contains("kokoro") {
                    profile.synth.cloneSourceVoice = false
                    profile.synth.podcastMode = true
                    if profile.synth.localVoice.isEmpty || profile.synth.localVoice == "Tingting" {
                        profile.synth.localVoice = "zm_010"
                    }
                } else {
                    profile.synth.cloneSourceVoice = false
                }
            }
        )
    }

    private var kokoroVoiceBinding: Binding<String> {
        Binding(
            get: {
                let v = profile.synth.localVoice.trimmingCharacters(in: .whitespaces)
                let known = ["zm_010", "zm_009", "zm_011", "zm_012", "zf_001", "zf_002", "zf_003", "zf_004", "af_heart", "am_adam"]
                return known.contains(v) ? v : "zm_010"
            },
            set: { profile.synth.localVoice = $0 }
        )
    }

    private var mlxModelBinding: Binding<String> {
        Binding(
            get: {
                let m = profile.synth.mlxModel.trimmingCharacters(in: .whitespaces)
                return m.isEmpty ? "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit" : m
            },
            set: { profile.synth.mlxModel = $0 }
        )
    }

    private var mlxVoicePresetBinding: Binding<String> {
        Binding(
            get: {
                let v = profile.synth.mlxVoice.trimmingCharacters(in: .whitespaces)
                let known = ["Dylan", "Vivian", "Uncle_Fu", "Serena", "Eric"]
                for k in known where v.hasPrefix(k) { return k }
                return "Dylan"
            },
            set: { profile.synth.mlxVoice = $0 }
        )
    }

    // MARK: 控件行

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).frame(width: 110, alignment: .leading)
                CinemaSlider(value: value, range: range, step: step)
                    .accessibilityLabel(label)
                    .frame(maxWidth: 420)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }
            if !hint.isEmpty {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 110)
            }
        }
        .padding(.vertical, 1)
    }

    private func stepperRow(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, hint: String) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            HStack(spacing: 12) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) } label: { Image(systemName: "minus") }
                    .disabled(value.wrappedValue <= range.lowerBound).accessibilityLabel("减少 " + label)
                Text("\(value.wrappedValue)").monospacedDigit().frame(minWidth: 28)
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) } label: { Image(systemName: "plus") }
                    .disabled(value.wrappedValue >= range.upperBound).accessibilityLabel("增加 " + label)
            }.frame(maxWidth: 260, alignment: .leading)
            if !hint.isEmpty {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
