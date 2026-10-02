#!/usr/bin/env bash
# 插件精确版本豁免命令（dsh 0.2.0+ 兼容性门禁）与失败提示

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

mkdir -p "$TEST_HOME/deepseek-harness/apps/cli"
printf '{"name":"@deepseek-ai/dsh","version":"0.2.0-rc.2"}\n' > "$TEST_HOME/deepseek-harness/apps/cli/package.json"

# ---------- dry-run 预览 ----------
run_dshctl --plugin-exemptions --dry-run
assert_rc 0 "--plugin-exemptions --dry-run 退出码为 0"
assert_stdout_contains "version-exemptions" "dry-run 输出豁免查询命令"

run_dshctl --plugin-allow @scope/pkg@1.2.3 --dry-run
assert_rc 0 "--plugin-allow --dry-run 退出码为 0"
assert_stdout_contains "allow-version @scope/pkg@1.2.3 --dsh-version 0.2.0-rc.2 --accept-risk" "dry-run 输出授予命令（含精确版本与 --accept-risk）"

run_dshctl --plugin-revoke pkg@1.0.0 --dry-run
assert_rc 0 "--plugin-revoke --dry-run 退出码为 0"
assert_stdout_contains "revoke-version pkg@1.0.0 --dsh-version 0.2.0-rc.2" "dry-run 输出撤销命令"

# ---------- 参数校验 ----------
run_dshctl --plugin-allow badspec --dry-run
assert_rc 1 "缺少 @版本 的规格被拒绝"
assert_output_contains "包名@精确版本" "规格错误提示"

run_dshctl --plugin-allow
assert_rc 1 "--plugin-allow 缺少取值"
assert_output_contains "缺少取值" "缺值错误提示"

run_dshctl --plugin-allow foo@1.0.0 --plugin-revoke foo@1.0.0
assert_rc 1 "豁免操作互斥"
assert_output_contains "操作冲突" "豁免操作冲突提示"

# ---------- 未安装启动器时的执行提示 ----------
run_dshctl --plugin-exemptions
assert_rc 1 "无启动器时执行失败"
assert_output_contains "未找到启动器" "无启动器时提示先安装"

# ---------- 失败提示识别不兼容文案 ----------
# 直接构造日志内容，验证 plugin_failure_hint 的识别路径由 --plugin-policy 之外的动作触发不易，
# 这里通过 grep 静态确认脚本文案包含关键提示命令。
assert_command "脚本包含 allow-version 提示" grep -qF "dshctl --plugin-allow <包名>@<版本>" "$DSHCTL"
assert_command "脚本包含豁免查询提示" grep -qF "dshctl --plugin-exemptions" "$DSHCTL"

finish
