#!/usr/bin/env bash
# CLI 基础行为：帮助、版本、无参数、未知选项

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

run_dshctl --help
assert_rc 0 "--help 退出码为 0"
assert_stdout_contains "用法:" "--help 输出用法说明"
assert_stdout_contains "--install" "--help 列出安装操作"
assert_stdout_contains "--plugin-policy" "--help 列出插件策略"
assert_stdout_contains "--model-fix" "--help 列出模型维护"
assert_stdout_contains "--data-backup" "--help 列出数据备份"
assert_stdout_contains "--rollback" "--help 列出版本回退"
assert_stdout_contains "--backups-prune" "--help 列出备份清理"
assert_stdout_contains "项目主页" "--help 输出项目主页"

run_dshctl -h
assert_rc 0 "-h 与 --help 等价"

run_dshctl
assert_rc 0 "无参数时显示帮助并正常退出"
assert_stdout_contains "用法:" "无参数输出帮助"

run_dshctl --version
assert_rc 0 "--version 退出码为 0"
script_version="$(sed -n 's/^DSHCTL_VERSION="\(.*\)"$/\1/p' "$DSHCTL")"
assert_stdout_contains "dshctl.sh v$script_version" "--version 输出版本号"
assert_stdout_contains "github.com/ThzxxArt/dshctl" "--version 输出项目主页"
assert_stdout_contains "已装 dsh" "--version 输出 dsh 安装状态"

run_dshctl -V
assert_rc 0 "-V 与 --version 等价"

run_dshctl --frobnicate
assert_rc 1 "未知选项退出码为 1"
assert_output_contains "未知选项" "未知选项给出错误提示"

run_dshctl --install --unknown-flag
assert_rc 1 "已知操作 + 未知选项仍报错"
assert_output_contains "未知选项" "混合场景错误提示"

finish
