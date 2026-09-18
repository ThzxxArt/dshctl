#!/usr/bin/env bash
# 全局命令注册与注销（软链行为，含幂等与指向保护）

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

LINK="$TEST_HOME/.local/bin/dshctl"

run_dshctl --register
assert_rc 0 "--register 退出码为 0"
assert_symlink_to "$LINK" "$DSHCTL" "软链指向本脚本"

run_dshctl --register
assert_rc 0 "重复 --register 幂等"
assert_symlink_to "$LINK" "$DSHCTL" "重复注册后软链不变"

run_dshctl --unregister
assert_rc 0 "--unregister 退出码为 0"
assert_file_absent "$LINK" "软链已移除"

run_dshctl --unregister
assert_rc 0 "重复 --unregister 幂等"
assert_stdout_contains "未注册" "重复注销给出提示"

# 同名非本脚本文件不得被删除
mkdir -p "$(dirname "$LINK")"
printf 'user file\n' > "$LINK"
run_dshctl --unregister
assert_rc 0 "同名普通文件场景退出码为 0"
assert_file_exists "$LINK" "同名普通文件未被误删"
assert_output_contains "未移除" "同名文件给出保护提示"

finish
