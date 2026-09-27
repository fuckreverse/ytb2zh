SWIFT := swift
APP_NAME := Ytb2ZH

.PHONY: build release test fast verify run-providers help clean

help:
	@echo "targets:"
	@echo "  make build           调试构建（CLI + GUI）"
	@echo "  make release         release 构建"
	@echo "  make test            全部单测（调度器/切分/SRT/模板/JobStore）"
	@echo "  make verify          逐引擎真机自检（转录+翻译+TTS+成片 30s 素材）"
	@echo "  make providers       列出七步可选引擎"
	@echo "  make templates       列出内置/用户模板"
	@echo "  make app             运行 GUI（Ytb2ZHApp）"
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

app: build
	.build/debug/Ytb2ZHApp

clean:
	$(SWIFT) package clean
