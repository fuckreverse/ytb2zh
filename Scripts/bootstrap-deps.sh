#!/bin/bash
# bootstrap-deps.sh — 重建 vendored 原生依赖（Frameworks/，不进 git，~131MB）
# 用法：在仓库根目录执行 ./Scripts/bootstrap-deps.sh
# 产物：
#   Frameworks/whisper.xcframework   — whisper.cpp b5130 官方 xcframework 裁剪出的 macOS slice
#   Frameworks/sherpa-onnx/lib/*.a   — sherpa-onnx v1.13.8 osx-arm64 静态库（去 portaudio）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/Frameworks"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$FW"

# ---------- 1) whisper.cpp b5130 xcframework（裁剪：只留 macOS slice + 手写 Info.plist） ----------
if [ ! -d "$FW/whisper.xcframework" ]; then
  echo "==> 下载 whisper.cpp b5130 xcframework ..."
  curl -fL --progress-bar -o "$TMP/whisper.zip" \
    "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip"
  echo "==> 解压并裁剪 whisper.xcframework ..."
  unzip -q "$TMP/whisper.zip" -d "$TMP/whisper"
  # 官方 zip 把 xcframework 嵌在 build-apple/ 下（SPM 要求 zip 根，不能直接 remote 引用）
  SRC="$TMP/whisper/build-apple/whisper.xcframework"
  [ -d "$SRC" ] || SRC="$(find "$TMP/whisper" -name whisper.xcframework -maxdepth 3 -type d | head -1)"
  mkdir -p "$FW/whisper.xcframework"
  cp -R "$SRC/macos-arm64_x86_64" "$FW/whisper.xcframework/"
  cat > "$FW/whisper.xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>whisper.framework/Versions/A/whisper</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>whisper.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundleIdentifier</key>
	<string>org.ggml.whisper</string>
	<key>CFBundleName</key>
	<string>whisper</string>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
else
  echo "==> whisper.xcframework 已存在，跳过"
fi

# ---------- 2) sherpa-onnx v1.13.8 osx-arm64 静态库 ----------
if [ ! -d "$FW/sherpa-onnx/lib" ]; then
  echo "==> 下载 sherpa-onnx v1.13.8 osx-arm64 静态库 ..."
  curl -fL --progress-bar -o "$TMP/sherpa.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-static-lib.tar.bz2"
  echo "==> 解压静态库（排除 portaudio）..."
  mkdir -p "$TMP/sherpa" "$FW/sherpa-onnx/lib"
  tar xjf "$TMP/sherpa.tar.bz2" -C "$TMP/sherpa"
  LIBDIR="$(find "$TMP/sherpa" -type d -name lib | head -1)"
  for f in "$LIBDIR"/*.a; do
    case "$(basename "$f")" in *portaudio*) continue ;; esac
    cp "$f" "$FW/sherpa-onnx/lib/"
  done
  echo "    $(ls "$FW/sherpa-onnx/lib" | wc -l | tr -d ' ') 个静态库"
else
  echo "==> sherpa-onnx 静态库已存在，跳过"
fi

echo "==> bootstrap 完成。现在可以 swift build / make build"
