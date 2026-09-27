SWIFT := swift
APP_NAME := Ytb2ZH
APP_BUNDLE := .build/Ytb2ZH.app

.PHONY: build release test fast verify run-providers help clean app app-fg icon

help:
	@echo "targets:"
	@echo "  make build           调试构建（CLI + GUI）"
	@echo "  make release         release 构建"
	@echo "  make test            全部单测（调度器/切分/SRT/模板/JobStore）"
	@echo "  make verify          逐引擎真机自检（转录+翻译+TTS+成片 30s 素材）"
	@echo "  make providers       列出七步可选引擎"
	@echo "  make templates       列出内置/用户模板"
	@echo "  make app             后台启动 GUI（不占终端）"
	@echo "  make app-fg          前台运行 GUI（终端阻塞直到退出，可看日志）"
	@echo "  make clean           清理 .build"

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release

test:
	$(SWIFT) test

verify: build
	.build/debug/ytb2zh verify

providers: build
	.build/debug/ytb2zh providers

templates: build
	.build/debug/ytb2zh templates list

app: bundle
	@open $(APP_BUNDLE)
	@echo "Ytb2ZH.app 已启动（make bundle 重新打包）"

# 打包 .app bundle（裸可执行无法被系统正确识别名称/图标，且无法做剪贴板/拖拽文件关联）
# 同时拷入 i18n 资源（Support/<lang>.lproj）与图标（Assets/AppIcon.icns，若有）
bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	@cp .build/debug/Ytb2ZHApp $(APP_BUNDLE)/Contents/MacOS/Ytb2ZHApp
	@cp -R Support/*.lproj $(APP_BUNDLE)/Contents/Resources/
	@if [ -f Assets/AppIcon.icns ]; then cp Assets/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/; fi
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleExecutable</key><string>Ytb2ZHApp</string>\n\t<key>CFBundleIdentifier</key><string>com.ytb2zh.app</string>\n\t<key>CFBundleName</key><string>ytb2zh</string>\n\t<key>CFBundleDisplayName</key><string>ytb2zh 实时译配</string>\n\t<key>CFBundlePackageType</key><string>APPL</string>\n\t<key>CFBundleShortVersionString</key><string>1.1</string>\n\t<key>LSMinimumSystemVersion</key><string>13.0</string>\n\t<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>\n\t<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>\n\t<key>CFBundleIconFile</key><string>AppIcon</string>\n\t<key>NSHumanReadableCopyright</key><string>MIT License</string>\n</dict>\n</plist>\n' > $(APP_BUNDLE)/Contents/Info.plist
	@echo "打包完成：$(APP_BUNDLE)"

# 生成图标：源 SVG → 1024px PNG → icns（需 rsvg-convert 或 qlmanage）
icon:
	@bash Tools/make_icon.sh

app-fg: build
	.build/debug/Ytb2ZHApp

clean:
	$(SWIFT) package clean
