# Videx

纯 Swift 的视频/音频流**提取**库（extraction only）。支持 **YouTube**、**Bilibili**、**抖音**、**TikTok**，目标是从"URL → 元数据 + 可下载流地址列表"一步到位，下载交给调用方（ffmpeg / URLSession / AVPlayer 均可）。

```swift
import Videx

let info = try await ExtractorRegistry.standard.extract(
    url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
    options: ExtractionOptions(proxy: "http://127.0.0.1:7890")
)
print(info.title)                       // 元数据
print(info.bestVideoOnly?.url ?? "-")   // 1080p+ 纯视频流
print(info.bestAudioOnly?.url ?? "-")   // 最高码率音频流
```

CLI 速查：

```bash
swift run videx "https://www.bilibili.com/video/BV1GJ411x7h7" --cookie SESSDATA=xxx
swift run videx "https://youtu.be/xxxx" --proxy http://127.0.0.1:7890 --clients tv_samsung,visionos --json
swift run videx "https://youtu.be/xxxx" --cookies ./cookies.txt --json
swift run videx "https://youtu.be/xxxx" --clients mweb --po-token "mweb.gvs+TOKEN" --visitor-data "MATCHING_VISITOR_DATA" --json
swift run videx "https://youtu.be/xxxx" --allow-missing-pot --json   # 调试：强制返回缺 POT 的格式
```

## 架构

```
Sources/Videx/
├── Core/                    # 站点无关的核心层
│   ├── MediaModels.swift    #   MediaInfo / MediaFormat / SubtitleTrack
│   ├── Extractor.swift      #   Extractor 协议 + ExtractorRegistry + 会话上下文
│   ├── HTTP/                #   HTTPFetching 协议 + URLSession 实现（代理/重定向）
│   ├── JS/                  #   JSRuntime 协议 + JavaScriptCore 实现 + 浏览器垫片
│   ├── Subtitles/           #   字幕下载与 SRT 转换（youtube-json3 / bilibili-json）
│   ├── JSONValue.swift      #   宽容 JSON 访问器 + QueryString
│   └── BraceMatcher.swift   #   混淆 JS 的函数/对象截取
├── YouTube/                 # InnerTube 多客户端轮询 + JSC 挑战求解
├── Bilibili/                # view/playurl(DASH) + WBI 签名 + 字幕
├── Douyin/                  # ttwid 风控注册 + web detail API
├── TikTok/                  # WAF PoW 原生求解 + universal data
└── Aweme/                   # 字节系 aweme 详情归一化解析（两端复用）
```

三条设计原则：

1. **站点插件化**：新站点 = 实现一个 `Extractor`（`canHandle` + `extract`），注册进 `ExtractorRegistry` 即可，核心层零改动。内部能力（HTTP/JS/Cookie/日志）全部协议化注入（`ExtractionContext`），任何一层都可替换——包括把 JS 引擎换成 node/deno 子进程。
2. **真实 JS 引擎，不自研解释器**：YouTube 播放器挑战（decipher/nsig）用系统 JavaScriptCore 直接执行提取出的挑战代码。上游 yt-dlp 已于 2025.11 官方放弃自研解释器路线，本库从第一天就站在真引擎路线。
3. **Extraction and download separation**: extractors produce MediaInfo; native Swift download APIs consume it. Existing ffmpeg handles container muxing only.

## 当前策略与已知限制

YouTube：

- 客户端矩阵与默认轮询顺序对齐 yt-dlp master（2026.10）：默认 `tv_samsung` → `visionos` → `web`；登录会话使用 `web_embedded` → `tv_samsung` → `web`（以 LOGIN_INFO + SAPISID 系 Cookie 判断，访客 Cookie 不视为登录）；所有客户端的格式合并去重，同格式的其他地址保留为备用 URL（`--clients` 可手动指定）；
- **PO Token 策略**：按客户端与协议过滤缺少必需 GVS Token 的格式，保留 itag 18 等豁免；调试可用 `--allow-missing-pot`。库与 CLI 可注入 `client.gvs`、`client.player`、`client.subs`（`ExtractionOptions.youtubePoTokens` 或 `--po-token client.context+TOKEN`）。匿名 GVS 绑定 visitorData，登录 GVS 使用完整 DATASYNC_ID，GVS 视频绑定实验及 player/subs 使用 videoID；配套 visitorData 通过 `youtubeVisitorData` 传入。上层 App 自动用 WKWebView 生成，并配套传递浏览器 Cookie、UA 和代理，缓存按请求范围隔离；库和独立 CLI 不会自动启动上层 WebView。详见 [WebPO 对齐记录](PO-TOKEN-PARITY.md)。
- 网页会话：复用 `ytInitialPlayerResponse`，传递 visitorData / X-Goog-Visitor-Id / signatureTimestamp；Cookie 登录生成 SAPISIDHASH / 1P / 3P 认证签名并传递账户索引，嵌入式请求携带 encryptedHostFlags；Cookie 文件支持 Netscape 格式、HttpOnly、过期、路径和 HTTPS 范围；
Native HLS downloading and resume have replaced ffmpeg network fetching; see the native expansion section below.
- `android_vr` 已废弃：上游 2026.08.17 起全格式 403（含 itag 18），已移出默认列表，保留仅供手动指定；
- 客户端版本号 / POT 标注需随上游风控定期同步（`InnerTubeClient` + `InnerTubeClientTests` 黄金值锁定，防止无意回退）。

Bilibili：

- DASH 流 + WBI 签名 + buvid3 风控兜底已实现；未登录走 `try_look` 通道（上限 480P），传入 `SESSDATA` Cookie 自动解锁高画质；

抖音：

- ttwid 自动注册（`ttwid.bytedance.com`，无签名要求）+ web detail API（`/aweme/v1/web/aweme/detail/`），未登录即可拿到 1080p H.264 混合流；登录 cookie（`--cookie sessionid=xxx`）可解锁更高码率档；
- 支持主站 /video、/note、iesdouyin 分享页、v.douyin.com 短链；短链目标被设为私密时透出站点 filter_detail 人话原因；
- 连续高频注册 ttwid 会触发瞬时 403 风控（稍后重试即可），生产使用建议复用进程级 ttwid。

TikTok：

- 网页 WAF 挑战（Slardar）**原生 PoW 求解**（sha256 碰撞，CryptoKit 实现，无需 JS 引擎，实测几十次迭代内命中），随后从 `__UNIVERSAL_DATA_FOR_REHYDRATION__` 提取视频数据；
- 流地址优先 `aweme/v1/play/` 端点（302 到签名 CDN，实测可 Range 下载）；直连 webapp CDN 在部分网络下 403，保留为备用 URL；
- 旧移动 API（api16/api22 feed/detail）对未签名客户端已返回空响应，不再使用；
- 支持 @user/video、/embed、vm/vt 短链；幻灯片/需登录内容抛分类错误。

## 测试

```bash
swift test --disable-sandbox  # 80 个测试；14 个外网测试默认跳过
VIDEX_LIVE=1 VIDEX_PROXY=http://127.0.0.1:7890 \
  swift test --filter LiveSmokeTests   # 真机冒烟（需外网/代理）
```

离线测试覆盖：URL 解析（四站点）、YouTube 挑战提取与 JSC 求解（合成混淆样本）、TikTok WAF PoW（合成 + 真实挑战页 fixture）、WBI 签名（黄金值由独立 Python 实现交叉验证）、aweme 解析（真实 app/web 响应 fixture）、DASH/player response 解析、字幕转换、Cookie/代理/注册表路由、InnerTube 客户端矩阵（默认顺序 / POT 标注 / 版本号黄金值锁定，对齐 yt-dlp 2026.10）、POT 过滤与 SABR-only 格式跳过、跨客户端合并/备用地址、HLS 清单/DRM、网页会话、Cookie 导入和认证黄金值。

## 来源与致谢

本库为独立实现，部分提取逻辑参考或移植自 [yt-dlp](https://github.com/yt-dlp/yt-dlp)（Unlicense，公有领域——复制、修改、再许可均无任何条件）；B 站 WBI 签名等另参考 bilibili-API-collect 等公开社区文档。各文件头部的来源注释仅为工程溯源便利，非许可义务。

### 对齐验证（2026-10-14）

对照 yt-dlp nightly `2026.10.10.233141`（`897341241`），直连无 Cookie：
Rick Astley `dQw4w9WgXcQ` 从 27 条 HTTPS 扩展到 28 条 HTTPS + 17 条 HLS，与上游媒体格式数一致；新增 itag 18 合一流。
这只是一个可用样本的验证，不代表全量兼容。反机器人校验仍可能需要更换出口或提供有效会话。

## Native download expansion (2026-10-14)

Extraction and download are separate APIs. Native Swift downloaders now handle HTTPS Range, DASH SegmentTemplate/Timeline/List, dynamic MPD windows, HLS AES-128 and SABR UMP/protobuf. They maintain durable checkpoints and refresh expired URLs. The App uses these native downloaders; its existing ffmpeg handles container remuxing only.

EJS 0.8.0 runs in the existing system JavaScriptCore, with bundled AST solver scripts and the previous fast path/cache. No yt-dlp backend, Node or Deno dependency is added. A real player fixture passes the EJS challenge test. Future player changes and unsupported JavaScriptCore features can still fail.

Explicit browser-file import supports Firefox and Chromium SQLite snapshots and Safari binarycookies. Chromium decryption uses system Keychain/CommonCrypto. Import reloads the selected file during extraction; it does not perform browser login. The macOS App provides native WKWebView WebPO generation; see [PO Token parity](PO-TOKEN-PARITY.md).

Format selection supports alternatives, merged streams, comma-separated outputs, filters, language/audio track/DRC selection, best/worst ordering. Playlist pagination, download archives, translated subtitles, chapters, comments and chat pagination/streaming have native APIs and CLI entry points.

Validation: 104 library tests passed (14 external tests skipped); 162 application tests passed (13 skipped). SABR is tested with protocol fixtures and real YouTube VOD audio/video transfer on dQw4w9WgXcQ (itags 137+140, 2 seconds). Live history is limited by the server's retained window. Not every yt-dlp format expression, MPD variant, comment reply tree or SABR live/ad transition is covered. This is not a claim of complete yt-dlp parity.

```bash
videx --download -f 'bv[height<=1080]+ba/b' --duration 10 --output ./downloads YOUTUBE_URL
videx --playlist --download --archive ./archive.json PLAYLIST_URL
videx --comments --chat-replay --max-pages 10 --output ./metadata YOUTUBE_URL
videx --cookies-from-browser firefox:/absolute/path/cookies.sqlite YOUTUBE_URL
```

原生 WKWebView PO Token 的后续修正、实测和边界见 [WebPO 对齐记录](PO-TOKEN-PARITY.md)。
