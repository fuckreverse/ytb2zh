# THIRD-PARTY NOTICES / 第三方组件与许可证

本仓库源码以 [MIT](LICENSE) 许可证分发。项目引入或使用的第三方组件遵循其各自的许可证，相关许可声明如下。本文件仅为便于合规的汇总说明，各组件以原作者发布的许可证文本为准。

## 1. 随源码内嵌（vendored in this repo）

| 组件 | 位置 | 许可证 | 来源 |
| --- | --- | --- | --- |
| demucs.cpp | `Sources/CDemucsCpp/demucs-src` | MIT (© 2023 Sevag H)，见目录内 [LICENSE](Sources/CDemucsCpp/demucs-src/LICENSE) | [sevagh/demucs.cpp](https://github.com/sevagh/demucs.cpp) |
| Eigen（数学库头文件） | `Sources/CDemucsCpp/eigen` | MPL-2.0 为主，部分文件为 BSD / Apache-2.0 / MinPack 等 MPL-2.0 兼容许可，详见目录内 `COPYING.*` | [eigen](https://gitlab.com/libeigen/eigen)（pinned dd8c71e，未修改） |
| sherpa-onnx C API 头 + shim | `Sources/CSherpaOnnx` | Apache-2.0 (© 2023 Xiaomi)，见目录内 [LICENSE](Sources/CSherpaOnnx/LICENSE) | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（官方 c-api.h，未修改） |
| bgutils-js（BotGuard 互操作，esbuild 打包为 IIFE 后内联于 `Sources/Ytb2ZHEngines/WebPoTokenScripts.swift`） | 源码内联 | MIT (© LuanRT) | [LuanRT/BgUtils](https://github.com/LuanRT/BgUtils)（pinned bgutils-js 4.0.3） |

说明：Eigen 为 MPL-2.0 文件级 copyleft——对本目录 Eigen 文件的任何修改须继续以 MPL-2.0 提供；demucs.cpp 的 C++ 源码与 `demucscpp_c.cpp` / `include/demucscpp.h` C shim 同样保留 MIT 声明。

## 2. 构建期下载（`Scripts/bootstrap-deps.sh`，不进 git）

| 组件 | 许可证 | 来源 |
| --- | --- | --- |
| whisper.cpp（whisper.xcframework，Metal/CoreML） | MIT | [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) 官方 Releases |
| sherpa-onnx（osx-arm64 静态库） | Apache-2.0 | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 官方 Releases |

⚠️ **GPL 注意**：sherpa-onnx 的 TTS（语音合成）功能在静态库内链接了 [espeak-ng](https://github.com/espeak-ng/espeak-ng)（**GPL-3.0**）与 piper-phonemize 等组件。仅以源码形式分发本仓库不受影响；但**若对外分发启用了 sherpa-onnx TTS 引擎的应用二进制**，该二进制（及随附的 espeak-ng 数据）需按 GPL-3.0 合规提供。可选规避：分发版本不捆绑/不启用 `sherpa-onnx` 合成引擎（本项目中它是可插拔的可选引擎，Edge TTS / 本地 say / 云端 TTS 均无此限制）。

## 3. 运行时按需下载（落 `~/.ytb2zh/models/` 等，不进 git）

| 组件 | 许可证 | 来源 |
| --- | --- | --- |
| whisper ggml 转录模型 | MIT | whisper.cpp 官方渠道（HuggingFace） |
| demucs htdemucs 分离权重 | MIT | [adefossez/demucs](https://github.com/adefossez/demucs)（"Demucs is released under the MIT license"） |
| sherpa-onnx vits TTS 模型 | Apache-2.0 | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 发布的模型 |
| yt-dlp（备用下载/搜索兑底） | Unlicense | [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp) 官方 Releases |

## 4. 用户自行安装的外部进程（本项目不捆绑、不分发）

- **ffmpeg / ffprobe**（LGPL-2.1+；Homebrew 默认构建含 GPL 组件时按 GPL-2.0+ 分发）：本项目以独立进程调用，不静态链接，不随仓库分发。分发本应用二进制时无需连带 ffmpeg；如选择捆绑则需自行遵守其许可证。

## 5. 网络服务（协议实现，不含第三方代码）

- **Microsoft Edge 在线 TTS**：`EdgeTTSSwift.swift` 为独立的协议实现，未复制 [rany2/edge-tts](https://github.com/rany2/edge-tts) 的任何代码（该仓库许可证为自定义条款），故不产生源码许可义务；实际使用受微软相应服务条款约束。
- **LLM 网关 / OpenAI 兼容 API / 阿里云百炼**：按各服务商的 API 服务条款使用。

## 6. Videx 提取逻辑来源

`Videx/` 为本项目的独立实现（MIT），其中部分提取逻辑参考或移植自 [yt-dlp](https://github.com/yt-dlp/yt-dlp)（**Unlicense**，公有领域奉献——复制、修改、再许可均无条件，不产生任何署名或开源义务）。相关文件头部有来源注释，仅为工程溯源便利。

## yt-dlp EJS 0.8.0

Embedded scripts: [yt-dlp/ejs](https://github.com/yt-dlp/ejs), Unlicense. Bundled Meriyah (ISC) and Astring (MIT) notices are retained in the JavaScript. See Videx/Sources/Videx/YouTube/Resources/EJS-LICENSE.txt. Native SABR protocol references [upstream SABR work](https://github.com/yt-dlp/yt-dlp/pull/13515), Unlicense.
