# 英文语音 → 中文语音（S2ST）调研

调研时间：2026-10-15　针对项目：ytb2zh（YouTube → 中文配音，macOS Swift App）

## 0. 现状链路（对照基准）

`Pipeline.swift` 的七步：

下载 → 人声分离(demucs) → **转写(whisper-native, 默认 ggml-base.en)** → 切分 → **翻译(Gateway LLM)** → **合成(bailian CosyVoice)** → 调度(DriftScheduler) → 合成(ffmpeg)

三个已知痛点：
1. 默认 ASR 是 `ggml-base.en`（142MB），对重口音/噪声/专有名词弱，错误会一路传播到翻译和字幕；
2. 中文 TTS 时长与英文源时长不匹配，靠 DriftScheduler 硬拉伸/压缩；
3. 链路长、每步都要缓存与断点续跑，慢且脆弱。

## 1. 结论速览

| 路线 | 代表方案 | 是否保原音色 | 时长对齐 | 字幕可编辑 | 术语注入 | 本地 Mac 可跑 | 成本 |
|---|---|---|---|---|---|---|---|
| 云 API 一键 S2S | 百炼 `qwen3-livetranslate-flash` | 否（预置音色） | 未承诺 | 有中文文本 | **不支持** | 否 | 按 token，低 |
| 云 API 一键 S2S | 火山 同声传译2.0 S2S / 视频翻译算子 | **是（声音复刻）** | **承诺精准对齐** | 有 | 未见 | 否 | 按量 |
| 云 API 一键 S2S | ElevenLabs Dubbing v2 | **是** | 同步感知 | **v2 不可编辑** | 否 | 否 | $2.20/min |
| 自部署开源 | B站 `Index-Echo-S2ST-2B/9B` | **是** | 较好 | 配套 S2TT 出带时间戳译文 | 未见 | 否（CUDA） | GPU 租金 |
| 自部署开源 | `UniSS`（ICLR 2026） | **是** | 显式时长一致性指标 | 有 | 未见 | 否（CUDA） | GPU 租金 |
| 自部署开源 | `DuraS2ST-Think-RL`（EMNLP 2026） | 是 | **显式时长规划** | 有 | 未见 | 否（A100 实测） | GPU 租金 |
| 改良级联 | 强 ASR + 音节可控翻译 + 可控 TTS | 可选 | 靠音节预算 | **有** | **有** | 部分可（mlx-audio） | 低 |

**关键判断**：端到端确实可用了，但「一步到位」会顺手丢掉本项目最值钱的三样东西——可校对可编辑的中文字幕、术语/领域注入、以及单元级时间轴控制。建议分层替换而不是整体替换。

## 2. 云端 API（最快落地）

### 2.1 阿里云百炼 · Qwen3-LiveTranslate-Flash（推荐先试）

- 模型：`qwen3-livetranslate-flash`，**Chat Completions 文件模式**，官方场景定位就是「视频配音 / 播客翻译」。
- 调用要点：
  - 输入：`input_audio`（公网 URL 或 base64，wav/mp3/aac 等），也可传 `video_url` 用视频拿视觉上下文提升翻译准确性；
  - `extra_body.translation_options = {source_lang: "en", target_lang: "zh"}`（省略 source_lang 则自动检测）；
  - `modalities=["text","audio"]` → 同时返回中文文本 + 24kHz 中文音频（base64，流式）；
  - `audio={"voice":"Cherry","format":"wav"}` → **只能选预置音色，不支持克隆原说话人**；
  - 只支持流式输出（`stream=True`），单轮、不支持 system message。
- 限制：上下文 53,248 / 最大输入 49,152 tok / 最大输出 4,096 tok；RPM 100，TPM 100k。
- 价格（华北2 北京）：输入音频 ¥10/M tok，输入图片 ¥4/M，输出文本 ¥10/M，**输出音频 ¥40/M tok**；有 100 万 token 免费额度。
- **致命短板**：不支持 system prompt → 术语表/领域语境喂不进去，会和现有 `TerminologyEngines` 冲突。

### 2.2 阿里云百炼 · Qwen3.5-Omni（要术语就换它）

- `qwen3.5-omni-plus` / `qwen3.5-omni-flash`，同样 Chat Completions 文件模式。
- 音频输入**最长 3 小时**（视频 1 小时，单文件 ≤2GB，base64 <10MB）；
- 输出文本 + 音频，`audio={"voice":"Tina"...}`，55 种音色；**plus / flash 支持声音复刻**；
- 文档未给出 system 角色示例，但明确支持用 user 文本指令注入要求（术语、领域、语速、情绪）→ 可替代现在的 `translateOptions.terminology`；
- 输出 29 种语言含中文，价格需看控制台。

### 2.3 火山引擎

- **同声传译 2.0**：有 `语音到语音(S2S)` 模式；**声音复刻模式**（不传 speaker_id 即自动复刻说话人），源/目标必须含中英，支持方言；另有「指定音色模式」传 speaker_id。
- **视频翻译算子（AI 数据湖服务）** / **视频点播「声影智译」**：输入 25 语种视频 → 输出 31 语种配音 + 字幕；官方明确「音色 1:1 还原 + 翻译后语音与原始时长精准对齐」，还有面容级口型对齐。基本等于把整条管线托管出去。
- 价格按量，需查控制台。

### 2.4 ElevenLabs Dubbing

- Dubbing v2 是**音频到音频**模型（不走转写→翻译→合成），保留原说话人音色、节奏、情绪，同步感知时序；29 语种配音 / 90+ 语种；单文件上限 2GB、180 分钟；最多 9 个说话人。
- 价格：**v2 $2.20/分钟**（按源时长 × 目标语言数计）；v1 无水印 $0.50/分钟，v1 才有可编辑的 Dubbing Studio。
- **v2 输出不可编辑**，且不提供口型同步 → 与本项目「字幕可改 + 时间轴可控」诉求冲突。

## 3. 自部署开源（品质上限最高）

### 3.1 B站 IndexTeam · Index-Echo-S2ST（首推自部署）

- 仓库 `bilibili/Index-Translate`，模型 `IndexTeam/Index-Echo-S2ST-2B`（约 13GB）/ `-9B`（约 26GB），**Apache-2.0**。
- 结构：Qwen3-Omni **AuT 音频编码器** + Index-Translate 解码器 → Hidden2CV mapper → **CosyVoice3**；源音频提 CampPlus 音色嵌入注入生成链路 → **保留原说话人音色**。
- 方向：**英→中/西/日**、中→英/西/日。`dub.py input_en.wav --lang zh -o dub_zh.wav`，源语种自动判定。
- 硬件：单张 CUDA 卡，2B ≥12GB、9B ≥24GB 显存；Linux；需 ffmpeg。**Mac 不可用**。
- 官方数据：全方向平均内容错误率优于级联 pipeline（9B 0.0551 vs 0.0596），**英→中 2B 端到端相对 pipeline 错误率降低近 40%**，音色保真度 ~0.72 与级联持平。
- 长音频：按 **60 秒窗口**分段，保留前 5 个窗口历史上下文维持语篇连贯；但官方提示按语句级调优，**单句 ≤30s** 为宜。
- 配套 `Index-Echo-S2TT`：语音 → **带时间戳**译文文本（时间偏差 0.395 @2B），可直接做字幕。
- 注意：`echo-s2st/README_zh.md` 引用了 `../../video-dub/`（人声分离 + VAD 切分 + 时间轴回贴）和 `video-dub/deploy/serve_s2st.py`（起 HTTP 服务），但查询仓库 `inference/` 目录时只看到 `echo-s2st`、`echo-s2tt`、`llm`——**video-dub 路径需实际克隆后核对**。

### 3.2 UniSS（ICLR 2026）

- 单阶段统一 S2ST，Qwen2.5-1.5B 基座 + BiCodec，**保留音色 / 情绪 / 时长一致性**；仅英↔中；2B（另有 0.5B 低资源版）。
- 官方：CVSS-T 上翻译保真度超过级联系统与 GPT-4o-audio、Qwen2.5-Omni；英→中时长一致性接近最优；支持 Quality / Performance 两种模式与 vLLM 批量。cc-by-4.0。

### 3.3 DuraS2ST-Think-RL（EMNLP 2026）

- 显式**时长对齐**的 S2ST：生成前先规划目标措辞与音节长度，用时长感知的多模态 RL 优化；英↔中；Apache-2.0；基于 Step-Audio 2。
- 直接对症本项目的「时间轴漂移」问题，但实测环境是 A100 80GB，门槛最高。

### 3.4 排除项

- **Kyutai Hibiki / Hibiki-Zero**：流式同传 + 音色迁移，自然度 MOS 3.73（Seamless 2.18），但覆盖方向是 **X→English**（法/西/葡/德→英），**没有英→中**，短期指望不上。
- **SeamlessM4T / SeamlessExpressive**：100 语种，但主观评测明显落后于新模型，且同样 CUDA。
- **mlx-audio 的 STS**：是语音转换（SAM-Audio、DialogueSidon），**不是跨语种翻译**。目前 Apple Silicon 上没有可用的英→中 S2ST。

## 4. 必须权衡的四件事

1. **字幕与可编辑性**：S2S 一次成型，中间没有可校对的中文字幕。项目现有 `words.json / units.json / translated.json` 与「人工修订术语后重跑」的流程会被架空。折中：走 **S2TT** 拿中文译文，再送现有 TTS。
2. **术语注入**：`qwen3-livetranslate-flash` 不支持 system prompt → 术语喂不进去。要术语就用 `qwen3.5-omni` + user 文本指令。
3. **时间轴**：S2S 不返回时间戳，段边界仍需自己给。好消息是可以**只用 VAD**（项目已内嵌 sherpa-onnx，可跑 Silero VAD），不再依赖 ASR 词级时间戳，切分反而更简单。
4. **本机可行性**：所有英→中 S2ST 都要 CUDA。要本地化只能上云 GPU（4090 24GB 起或租卡），或走云 API。项目已经有 Gateway / Bailian 两个云引擎，接第三个体量不大。

## 5. 建议的落地步骤

**Step 1（1–2 天，先验证收益）**
在 `Ytb2ZHEngines` 新增 `S2STEngine`（实现新的 `SpeechToSpeechEngine` 协议），先用百炼 `qwen3-livetranslate-flash`：
- 用 VAD 切出语音段 → 每段 wav 送 API → 拿中文音频（写 clause cache）+ 中文文本（写 units.zh）；
- 时间轴沿用 VAD 段边界，调度器不变；
- 用现成的**试转模式（前 N 秒）**与现有链路 A/B 对比；
- 注意 49,152 token 输入上限，单段控制在几分钟内。

**Step 2（若音色/时长一致性是核心诉求）**
- 租一台 4090/24GB 云机，跑 Index-Echo-S2ST-2B 的 HTTP 服务，把 Step1 的引擎后端换成它；
- 同时保留 S2TT 分支出字幕，别砍掉术语提取与字幕校对。

**并行（低风险改良）**
- ASR 从 `ggml-base.en` 升到 `large-v3-turbo` 或云端 Qwen3-ASR（立竿见影，错误传播少一半）；
- 翻译改为**音节可控**（B站 Index-Homura：目标音节数显式条件，81.92% 输出音节偏差 ≤10%），从源头缓解 DriftScheduler 的压力；
- TTS 侧换 CosyVoice3 / IndexTTS2 / Qwen3-TTS（mlx-audio 有 Swift 包，可在 Mac 本地跑）。
