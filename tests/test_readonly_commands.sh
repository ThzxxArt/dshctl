#!/usr/bin/env bash
# 只读命令：无安装环境下应正常输出/合理报错，而不是崩溃

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

run_dshctl --status
assert_rc 0 "空环境下 --status 退出码为 0"
assert_stdout_contains "DeepSeek Harness 状态" "状态标题"
assert_stdout_contains "源码目录" "状态包含源码目录"
assert_stdout_contains "未安装" "状态显示未安装"

run_dshctl --backups-list
assert_rc 0 "空环境下 --backups-list 退出码为 0"
assert_stdout_contains "没有任何备份" "备份清单为空提示"

run_dshctl --data-backup
assert_rc 0 "无运行数据时 --data-backup 直接返回"
assert_stdout_contains "无需备份" "无数据备份提示"

run_dshctl --data-prune
assert_rc 0 "无缓存时 --data-prune 直接返回"
assert_stdout_contains "没有可清理的缓存项" "无缓存提示"

run_dshctl --url
assert_rc 1 "无服务日志时 --url 失败并提示"
assert_output_contains "未找到服务日志" "url 缺少日志的错误提示"

run_dshctl --logs
assert_rc 1 "无日志时 --logs 失败并提示"
assert_output_contains "没有可跟踪的日志" "logs 缺少日志的错误提示"

run_dshctl --plugin-list
assert_rc 0 "未初始化 profile 时 --plugin-list 正常提示"
assert_stdout_contains "profile 未初始化" "profile 未初始化提示"

finish
