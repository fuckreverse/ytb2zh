import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 引擎选择行（每步一个 Picker，数据来自 EngineRegistry）

struct EnginePickerRow: View {
    @Binding var profile: Profile
    private let registry = EngineAssembly.registry()

    var body: some View {
        Section("引擎（可插拔）") {
            ForEach(registry.offers, id: \.step) { offer in
                LabeledContent(L(offer.step.label)) {
                    Picker(L(offer.step.rawValue), selection: binding(for: offer.step)) {
                        ForEach(offer.descriptors, id: \.id) { d in
                            Text(d.name).tag(d.id)
                        }
                    }
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

    var body: some View {
        Section("语音合成") {
            synthEngineParams
        }

        Section("翻译风格") {
            LabeledContent("风格") {
                Picker("", selection: $profile.translate.style) {
                    ForEach(TranslationStyle.allCases, id: \.self) { s in
                        Text(L(s.label)).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            LabeledContent("质量") {
                Picker("", selection: $profile.translate.quality) {
                    ForEach(TranslationQuality.allCases, id: \.self) { q in
                        Text(L(q.label)).tag(q)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            LabeledContent("目标语言") {
                Picker("", selection: $profile.translate.targetLanguage) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            Toggle("启用术语表（翻译前提取/人工修订）", isOn: $profile.translate.useTerminology)
            Toggle("自动扩译（填不满时间窗时扩写）", isOn: $profile.translate.autoExpand)
            stepperRow("批次大小", value: $profile.translate.batchSize, in: 4...40, hint: "每批翻译条数")
            stepperRow("并发批次", value: $profile.translate.concurrency, in: 1...8, hint: "")
        }

        Section {
            DisclosureGroup(isExpanded: $advancedExpanded) {
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
                sliderRow("字幕字号", value: $profile.compose.subtitleFontSize, in: 10...28, step: 1, hint: "")
                sliderRow("字幕底边距", value: $profile.compose.subtitleMarginV, in: 10...80, step: 2, hint: "")
                sliderRow("单行字数上限", value: Binding(
                    get: { Double(profile.compose.subtitleMaxLength) },
                    set: { profile.compose.subtitleMaxLength = Int($0) }),
                    in: 16...90, step: 1, hint: "Netflix 标准：超长行自动二次拆分")
                sliderRow("行长偏置", value: $profile.compose.subtitleTargetMultiplier, in: 1.0...2.0, step: 0.1,
                          hint: "1.2 = 预期行长 = 上限/1.2，越大切得越碎")
                Toggle("中英双语字幕", isOn: $profile.compose.bilingualSubtitles)
                sliderRow("配音增益", value: $profile.compose.dubGainDB, in: 0...10, step: 0.5, hint: "dB")
                Toggle("保留 BGM（需人声分离引擎）", isOn: $profile.compose.keepBGM)
                sliderRow("BGM 增益", value: $profile.compose.bgmGainDB, in: -12...3, step: 0.5,
                          hint: "dB，负值压低伴奏")
                Toggle("保留原声（闪避混入，未分离时用）", isOn: $profile.compose.keepOriginalAudio)
                stepperRow("CRF", value: $profile.compose.crf, in: 14...30, hint: "越小越清晰越大")
            } label: {
                Text("高级参数（对齐调度 · 语义切分 · 字幕混音）")
                    .foregroundStyle(advancedExpanded ? Color.accentColor : .primary)
            }
        } header: {
            Text("微调（默认值已足够好，不确定别改）")
        }
    }

    // MARK: 合成参数随引擎联动：只显示当前引擎需要的参数，避免“改了也不生效”的误导

    @ViewBuilder
    private var synthEngineParams: some View {
        switch synthEngineID {
        case "edge-tts":
            LabeledContent("Edge TTS 音色") {
                Picker("", selection: $profile.synth.edgeVoice) {
                    Text("云希（年轻男声）").tag("zh-CN-YunxiNeural")
                    Text("晓晓（女声）").tag("zh-CN-XiaoxiaoNeural")
                    Text("云野（男声）").tag("zh-CN-YunyeNeural")
                    Text("晓伊（女声）").tag("zh-CN-XiaoyiNeural")
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case "local-say":
            LabeledContent("本地 say 音色") {
                Picker("", selection: $profile.synth.localVoice) {
                    Text("婷婷（经典女声）").tag("Tingting")
                    Text("波波（增强女声）").tag("Bobo (Enhanced)")
                    Text("Eddy（男声）").tag("Eddy (中文（中国大陆）)")
                    Text("Flo（女声）").tag("Flo (中文（中国大陆）)")
                    Text("Rocko（男声）").tag("Rocko (中文（中国大陆）)")
                    Text("Shelley（女声）").tag("Shelley (中文（中国大陆）)")
                }
                .labelsHidden()
                .frame(width: 220)
                .help("macOS 系统语音，离线可用；更多音色在系统设置 → 辅助功能 → 朗读内容安装")
            }
        case "sherpa-onnx":
            LabeledContent("Sherpa-Onnx 模型目录") {
                TextField("如 ~/sherpa-onnx/vits-zh-hf-theresa", text: $profile.synth.sherpaOnnxModelDir)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
            }
            .help("目录需含 model.onnx、tokens.txt、dict/；二进制自动查找 ~/sherpa-onnx/bin/ 或 PATH。从 github.com/k2-fsa/sherpa-onnx/releases 下载")
        case "openai-tts":
            Text("音色/模型在「应用设置 → 模型提供商」按能力配置")
                .font(.callout).foregroundStyle(.secondary)
        case "none":
            Text("当前模板不配音（仅字幕）；改用配音请在上方「语音合成」步选择引擎")
                .font(.callout).foregroundStyle(.secondary)
        default:
            // bailian（默认）：百炼音色 + 并发
            LabeledContent("音色") {
                Picker("", selection: $profile.synth.voice) {
                    Text("安明远（沉稳男声）").tag("anmingyuan_v3.1")
                    Text("火烛时（开朗男声）").tag("huozhuoshi_v3.1")
                    Text("龙三叔（东北男声）").tag("longsanshu_v3.1")
                    Text("许言初（儒雅男声）").tag("xuyanchu_v3.1")
                    Text("于晓云（知性女声）").tag("yuxiaoyun_v3.1")
                    Text("清歌（温柔女声）").tag("qingge_v3.2")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            stepperRow("并发数", value: $profile.synth.rps, in: 1...5, hint: "百炼限流 RPS=3")
        }
    }

    private func groupHeader(_ label: String) -> some View {
        Text(label)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: 控件行

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).frame(width: 110, alignment: .leading)
                Slider(value: value, in: range, step: step)
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
            Stepper("\(value.wrappedValue)", value: value, in: range)
                .frame(maxWidth: 260, alignment: .leading)
            if !hint.isEmpty {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
