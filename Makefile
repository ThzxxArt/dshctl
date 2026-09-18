# dshctl 开发入口
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

DSHCTL := dshctl.sh

.PHONY: help check syntax lint test version release

help: ## 显示可用目标
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

check: lint test ## 运行全部检查（静态检查 + 测试套件）

syntax: ## bash 语法检查
	bash -n $(DSHCTL)

lint: syntax ## ShellCheck 静态检查（warning 级别）
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "未找到 shellcheck，请先安装："; \
		echo "  Ubuntu/Debian: sudo apt-get install shellcheck"; \
		echo "  macOS:         brew install shellcheck"; \
		exit 1; \
	}
	shellcheck --severity=warning -x $(DSHCTL) tests/*.sh

test: ## 运行测试套件
	bash tests/run.sh

version: ## 打印脚本版本
	@sed -n 's/^DSHCTL_VERSION="\(.*\)"$$/dshctl v\1/p' $(DSHCTL)

release: check ## 校验后创建 v<版本> 注释 tag（不自动推送）
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "工作区不干净，请先提交所有改动"; exit 1; \
	fi
	@v="$$(sed -n 's/^DSHCTL_VERSION="\(.*\)"$$/\1/p' $(DSHCTL))"; \
	[ -n "$$v" ] || { echo "无法解析 DSHCTL_VERSION"; exit 1; }; \
	git tag -a "v$$v" -m "dshctl v$$v"; \
	echo "已创建 tag v$$v，推送: git push origin main v$$v"
