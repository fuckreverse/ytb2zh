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
swift run videx "https://youtu.be/xxxx" --proxy http://127.0.0.1:7890 --clients ios,web --json
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
3. **提取与下载分离**：库只产出 `MediaInfo`（含流地址、备用 CDN、字幕轨），不内置下载器，保持单一职责。

## 当前策略与已知限制

YouTube：

- 主力通道是 InnerTube 的移动/VR 客户端（`ios` / `android_vr` 等），返回**免解签直链**，多客户端轮询容错；
- WEB 客户端已进入 PO Token 风控范围（UNPLAYABLE），非默认主力；
- **已知限制**：2026 起 YouTube 将部分 decipher/nsig 挑战迁移到 WASM，JSC 求解器对这类新版本无能为力（表现为 graceful 跳过，不影响免解签客户端）。WASM 挑战理论上可经 JSC 的 WebAssembly 支持实现，属后续工作；
- 客户端版本号需随上游风控定期同步（`InnerTubeClient`）。

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
swift test                    # 46 个离线测试
VIDEX_LIVE=1 VIDEX_PROXY=http://127.0.0.1:7890 \
  swift test --filter LiveSmokeTests   # 真机冒烟（需外网/代理）
```

离线测试覆盖：URL 解析（四站点）、YouTube 挑战提取与 JSC 求解（合成混淆样本）、TikTok WAF PoW（合成 + 真实挑战页 fixture）、WBI 签名（黄金值由独立 Python 实现交叉验证）、aweme 解析（真实 app/web 响应 fixture）、DASH/player response 解析、字幕转换、Cookie/代理/注册表路由。
