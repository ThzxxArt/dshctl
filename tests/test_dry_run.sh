#!/usr/bin/env bash
# --dry-run：预览不产生任何副作用

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

# 预置一个"源码目录"用于验证 dry-run 不会删除任何东西
mkdir -p "$TEST_HOME/deepseek-harness/.git"
printf 'do not delete\n' > "$TEST_HOME/deepseek-harness/keep.txt"

run_dshctl --dry-run
assert_rc 0 "单独 --dry-run 视为安装预览"
assert_stdout_contains "安装计划预览" "输出安装计划"
assert_stdout_contains "源码目录" "输出源码目录信息"
assert_stdout_contains "dry-run 结束" "明确提示未做改动"

run_dshctl --install --dry-run
assert_rc 0 "--install --dry-run 退出码为 0"
assert_stdout_contains "安装计划预览" "安装预览输出"

run_dshctl --install --dry-run --clean-build
assert_rc 0 "--clean-build --dry-run 退出码为 0"
assert_stdout_contains "pnpm run clean" "dry-run 展示清理构建产物"

# 构建失败指引的静态存在性（真实构建失败需要完整仓库，此处仅防回归删除）
assert_command "脚本包含构建失败指引" grep -qF "dshctl --install --clean-build" "$DSHCTL"

run_dshctl --purge --dry-run
assert_rc 0 "--purge --dry-run 退出码为 0"
assert_stdout_contains "以上为预览" "卸载预览不执行删除"

run_dshctl --uninstall --dry-run
assert_rc 0 "--uninstall --dry-run 退出码为 0"

# 无副作用断言
assert_file_exists "$TEST_HOME/deepseek-harness/keep.txt" "dry-run 未删除源码目录内容"
assert_file_absent "$TEST_HOME/.local/bin/dsh" "dry-run 未安装启动器"
assert_file_absent "$TEST_HOME/.local/bin/dshctl" "dry-run 未注册全局命令"
assert_file_absent "$TEST_HOME/.dsh" "dry-run 未创建运行数据目录"
assert_file_absent "$TEST_HOME/.dshctl.lock" "dry-run 未创建安装锁"

finish
