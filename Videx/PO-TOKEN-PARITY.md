# 原生 WebPO 对齐记录（2026-10-15）

对照 [yt-dlp 的绑定规则](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/pot/utils.py)、[请求契约](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/pot/provider.py) 和 [PO Token Guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide)。

## 已修复的差距

| 项目 | 原实现 | 本轮实现 |
| --- | --- | --- |
| GVS | 统一绑定 visitorData | 匿名 visitorData、登录 DATASYNC_ID；开启实验的客户端绑定 videoID |
| player / subs | 复用 visitor Token；字幕未注入 | 单独铸造 videoID Token，分别注入 player API 和字幕 URL |
| 字幕 | 无专用完整请求参数 | `pot`、`potc=1`、正确客户端 `c`，保留原有语言及格式参数 |
| 缓存 | 一个全局 pot.json | 按视频、Cookie 会话及代理隔离；兼容读取旧结构，但旧 visitor-only Token 不升级为 player Token |
| 有效期 | 固定保守上限 | 服务端 integrity TTL 与六小时上限取小值，再扣除提前续期余量；缺失 TTL 拒绝缓存 |
| 代理 | 只有 interpreter 下载使用配置代理 | WKWebView 和原生请求都使用配置代理（HTTP/HTTPS/SOCKS5）；续传刷新保持原下载出口 |
| 会话 | WKWebView 默认持久化会话，可能与提取 Cookie 不同 | 隔离的 WebKit data store，显式导入选择的 Cookie，再将生成时的 Cookie 和浏览器 UA 配套传给提取/媒体/字幕及原声播放；播放保留解析出口，敏感请求头限制为同源 |
| 触发时机 | 全部格式提取失败后才生成 | 正常提取即可自动获取；403/过期刷新时可强制续期；保留关闭开关 |
| 并发 | 并发请求触发全局节流 | 相同请求共享一次生成，节流与缓存分别按请求范围隔离 |
| WebPO 客户端 | 仅 web / mweb / embedded | 覆盖库已实现的 WEB、MWEB、WEB_EMBEDDED_PLAYER、TVHTML5、TVHTML5_SIMPLY 系列；不把 WebPO Token 冒充 Android/iOS 原生证明 |
| 清单 | DASH 未注入 Token | HTTPS/HLS/DASH/SABR 各自带 GVS Token；DASH 清单补齐 n 挑战和缺 Token 过滤 |

## 实测证据

- WKWebView 执行真实 BotGuard，产出独立的会话 Token 和视频 Token；缓存往返通过。
- `dQw4w9WgXcQ`：仅 WEB 客户端，无免 Token 客户端兜底；原生 SABR 音频下载成功，字幕 HTTP 200，返回 8325 字节。测试入口：`POT_LIVE=1 POT_LIVE_DOWNLOAD=1 swift test --filter WebPoTokenLiveTests.testWebOnlySABRDownloadWithNativeProvider`。
- `rQE3w8Qjx98`：有新生成的原生 WebPO Token 仍返回 `LOGIN_REQUIRED / Sign in to confirm you're not a bot`。不带凭据的 yt-dlp nightly `2026.10.10.233141` 在相同出口也返回该错误。
- 用户随后明确授权同会话对照，已完成；两边使用同一视频对应的原生 Token/Cookie 和浏览器 UA，通过直连验证。完整脱敏结果见 [同会话报告](Reports/webpo-same-session-2026-10-15.json)。

## 范围和边界

这里对齐的是应用中原生 WebPO provider 的绑定、传递、缓存及网络会话语义。Videx 库仍可由调用方注入 `client.context` Token；独立 videx CLI 不会自动启动上层应用的 WKWebView provider。

不新增 yt-dlp、Node、Deno 或第三方服务依赖。BotGuard 由系统 WKWebView 执行。原生 Android/iOS attestation、yt-dlp 的第三方 provider 插件生态不属于该 WebPO provider。

PO Token 不能替代有效的账号权限或可靠出口。登录账号、地区限制、所有客户端实验组合和所有代理环境尚未逐一实测，不能宣称所有 YouTube 视频都能下载。

离线回归：库 104 项（外网跳过 14 项）；主项目新增绑定、缓存隔离、并发合并及播放会话测试。真实 WEB-only 测试还验证字幕 JSON 含非空时间轴事件，排除 HTTP 200 空响应。

## 用户授权后的同会话严格对照

通过官方 nightly 发布 API 确认，测试时最新构建为 `2026.10.10.233141`。两边只启用 WEB 客户端，输入来自同一原生会话缓存，匹配 WKWebView UA，使用直连；yt-dlp 分别尝试会话绑定和视频绑定的 GVS Token，player/subs 均为视频绑定。

| 视频/请求 | Videx | yt-dlp nightly |
| --- | --- | --- |
| `rQE3w8Qjx98` player | LOGIN_REQUIRED：确认不是机器人 | 相同提示，两种 GVS 绑定均失败 |
| `dQw4w9WgXcQ` HTTPS itag 18 | HTTP 206，读取 65536 字节 | HTTP 206，读取 65536 字节 |
| 同视频 JSON3 字幕 | HTTP 200，8325 字节，非空时间轴 | HTTP 200，8325 字节，61 个事件 |
| 同视频原生 SABR 音频 | 2 秒实际下载通过 | 当前基线未做 SABR 下载比较 |

原链接在相同会话输入下两边都无法通过登录校验。本次未发现需要继续修改的 PO Token 接入差异；这不证明所有视频、账号和客户端实验都已完全兼容，也不能替代真实登录权限或可靠网络环境。

测试中的 yt-dlp 与现有 Node 只用于基线对照，不是 Videx 的运行依赖。日志和报告不包含 Token、Cookie、visitorData 或带凭据的媒体 URL。


## Provider 社区再核对（2026-10-15，第二轮）

发现并修正一个此前对照未覆盖的问题：stage1 从新首页响应取 `ytAtN` 挑战，stage2 却在原 watch 页的 `yt.config_` 下运行。两次响应的 `EVENT_ID` 不保证相同。bgutil 的 [SessionManager](https://github.com/Brainicism/bgutil-ytdlp-pot-provider/blob/master/server/src/session_manager.ts) 明确把挑战与同一首页响应中的配置配对，供 BotGuard 读取 `yt.config_.EVENT_ID`。

本轮同时返回首页的 attestationConfig，在解释器执行前临时安装配套 `yt.config_`，铸币结束或失败后恢复 watch 页配置。visitorData、DATASYNC_ID 和视频实验标志仍取原浏览器会话；挑战配置不取代提取会话。缓存 scope 增加版本前缀，避免复用修正前的 Token。配置缺失时报告错误，不继续使用不匹配的配置。

此修正保证本地输入配对，不等于已经证明服务端信任度提高或原链接恢复。

| 路线 | 核对结果 | 对 Videx 的意义 |
| --- | --- | --- |
| [bgutil provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider) | HTTP 服务或 Node/Deno 脚本执行 BgUtils；当前实现取首页挑战和匹配配置，旧 `/Create` 已不可用 | 已有 WKWebView + BgUtils 属于同类路线；先修输入差异，不能把“多装一个 provider”当作必然解决登录校验 |
| [WPC provider](https://github.com/coletdjnz/yt-dlp-getpot-wpc) | Chrome/nodriver 调用页面原生 WebPoClient；支持访客和登录会话、GVS/player | 是另一种值得实测的铸币路径。当前源码依赖混淆入口 `window.top['havuokmhhs-0'].bevasrs.wpc`、`bg_st_hr` 实验和 `mws`，带就绪重试；不是稳定公共 API。已接入显式实验测试入口（`POT_METHOD=wpc`），默认生产路径不启用；不持久化其未声明 TTL 的 Token，不能标记为通用稳定支持 |
| [Rust provider](https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs) | rustypipe-botguard 的独立二进制实现 | 主要改变运行环境与部署方式；没有证据说明它必然解决当前 player 登录拒绝 |
| [旧 trusted-session-generator](https://github.com/iv-org/youtube-trusted-session-generator) | 上游明确标记 deprecated，并要求迁移到 companion | 不应作为新实现基础 |
| [Invidious companion](https://github.com/iv-org/invidious-companion) | 独立检索媒体服务，Deno 开发运行，也能编译单文件 | 可以作为独立基线研究；引入服务不等于修好 Videx 原生下载链路 |

新增显式联网验收入口，使用全新原生 Token，逐个尝试 mweb、web_safari、web，并下载完整 muxed HTTPS 文件：

```bash
POT_LIVE=1 POT_LIVE_FULL_DOWNLOAD=1 POT_VIDEO_ID=rQE3w8Qjx98 \
  swift test --disable-sandbox --filter WebPoTokenLiveTests.testPublicVideoProviderClientDownloads
# 可选 POT_PROXY=http://127.0.0.1:7890；默认控制视频 dQw4w9WgXcQ。
```

此测试只有真正下载成功才通过；所有客户端均失败时记为失败，不将反机器人拒绝转换成 skip。没有 muxed HTTPS 流会单独报告，不能据此推断其他协议也不可用。输出只记客户端、结果、字节数和本地路径，不记录 Cookie、Token 或签名媒体 URL。

第二轮实测（直连、无导入登录 Cookie）：

- 配置配对修正后，BgUtils 路径通过 mweb、web_safari、web 各完成一次控制视频的整片下载，均为 11,829,048 字节、213.043084 秒、H.264 640×360 + AAC；其中 mweb 文件完整 FFmpeg 解码退出 0，无错误日志。
- 原链接 `rQE3w8Qjx98`：三个客户端均 `LOGIN_REQUIRED`。没有将失败算作 skip。
- WPC 实验按上游加载首页 `?themeRefresh=1` 后成功铸币；原链接的三个客户端仍均 `LOGIN_REQUIRED`。直接在 watch 页初始化时曾出现页面内部 `InvalidTransition` 错误，故实验入口遵循上游的首页初始化方式。
- WPC 路径与现有 provider 同样使用系统 WKWebView，没有新增 Chrome、Python、Node 或 Deno 运行依赖。该实验不改变默认下载策略。
- 离线 provider 测试 9 项通过；独立 videx CLI 构建及新增参数解析检查通过。完整脱敏记录见 [第二轮报告](Reports/provider-research-2026-10-15.json)。

WPC 控制组后续结果：mweb、web_safari、web 均完成控制视频整片下载，各 11,829,048 字节；ffprobe 确认各文件均为 213.043084 秒、H.264 640×360 + AAC。两条路径的控制组均成功，原链接均在 player API 阶段失败。
