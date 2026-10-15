SWIFT := swift
CONFIGURATION ?= debug
APP_NAME := Ytb2ZH
APP_BUNDLE := .build/Ytb2ZH.app

.PHONY: build release test fast verify run-providers help clean app app-fg icon bundle

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
bundle:
	@CONFIGURATION=$(CONFIGURATION) ./Scripts/bundle-app.sh

# 生成图标：源 SVG → 1024px PNG → icns（需 rsvg-convert 或 qlmanage）
icon:
	@bash Tools/make_icon.sh

app-fg: build
	.build/debug/Ytb2ZHApp

clean:
	$(SWIFT) package clean
