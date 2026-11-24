#!/usr/bin/env bash
# --plugin-registry：单次插件操作的 npm 注册表透传、别名与参数校验

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

mkdir -p "$TEST_HOME/deepseek-harness/apps/cli" "$TEST_HOME/deepseek-harness/.git" \
  "$TEST_HOME/.local/bin"
printf '{"name":"@deepseek-ai/dsh","version":"0.2.3-alpha.2"}\n' \
  > "$TEST_HOME/deepseek-harness/apps/cli/package.json"

CALLS="$TEST_HOME/plugin-calls.txt"
REG='https://registry.npmjs.org'

write_launcher() { # $1=退出码
  make_stub "$TEST_HOME/.local/bin/dsh" "#!/usr/bin/env bash
printf '%s\n' \"\$*\" >> \"$CALLS\"
exit ${1:-0}"
}

# ---------- 帮助与静态约束 ----------
run_dshctl --help
assert_rc 0 "--help 退出码为 0"
assert_stdout_contains "--plugin-registry URL" "帮助列出 --plugin-registry"
assert_stdout_contains "--registry=URL" "帮助说明 --registry 别名"
assert_command "--npm-mirror 同时导出 pnpm_config_registry" \
  grep -qF 'export pnpm_config_registry=' "$DSHCTL"

# ---------- dry-run：规范化末尾斜杠并展示透传参数 ----------
write_launcher 0
run_dshctl --dry-run --plugin-update --plugin-registry "${REG}/"
assert_rc 0 "--plugin-update --dry-run 退出码为 0"
assert_output_contains "插件注册表: ${REG}（仅本次操作）" "输出本次注册表"
assert_output_contains "update --registry=${REG}" "dry-run 展示 update 透传（去除末尾斜杠）"

run_dshctl --dry-run --plugin-add some-plugin@1.0.0 --registry="${REG}"
assert_rc 0 "--plugin-add --dry-run（别名 --registry=）退出码为 0"
assert_output_contains "add some-plugin@1.0.0 --registry=${REG}" "dry-run 展示 add 透传"

run_dshctl --dry-run --plugin-repair --plugin-registry "$REG"
assert_rc 0 "--plugin-repair --dry-run 退出码为 0"
assert_output_contains "install --registry=${REG}" "dry-run 说明 repair 的 install 使用注册表"

# ---------- 实际执行：add / update / repair 的参数顺序 ----------
write_launcher 0
run_dshctl --plugin-add some-plugin@1.0.0 --plugin-registry "$REG"
assert_rc 0 "带注册表的插件安装成功"
assert_command "add 透传 --registry" \
  grep -qxF "plugin --profile web add some-plugin@1.0.0 --registry=${REG}" "$CALLS"

: > "$CALLS"
run_dshctl --plugin-update some-plugin --plugin-registry="${REG}"
assert_rc 0 "带注册表的指定插件更新成功"
assert_command "update 透传 --registry" \
  grep -qxF "plugin --profile web update some-plugin --registry=${REG}" "$CALLS"

: > "$CALLS"
run_dshctl --plugin-update --plugin-registry "$REG"
assert_rc 0 "带注册表的全量更新成功"
assert_command "全量 update 也透传 --registry" \
  grep -qxF "plugin --profile web update --registry=${REG}" "$CALLS"

: > "$CALLS"
run_dshctl --plugin-add some-plugin@1.0.0 --registry "$REG"
assert_rc 0 "--registry 空格形式可用"
assert_command "--registry 空格形式透传" \
  grep -qxF "plugin --profile web add some-plugin@1.0.0 --registry=${REG}" "$CALLS"

: > "$CALLS"
run_dshctl --plugin-repair --plugin-registry "$REG"
assert_rc 0 "带注册表的锁文件修复成功"
assert_command "repair 的 clean 步骤不带注册表" \
  grep -qxF "plugin --profile web clean --lockfile" "$CALLS"
assert_command "repair 的 install 步骤带注册表" \
  grep -qxF "plugin --profile web install --registry=${REG}" "$CALLS"

# ---------- 校验：非法 URL / 非法操作 / 空值 ----------
write_launcher 0
run_dshctl --dry-run --plugin-update --plugin-registry 'ftp://mirror.example.com'
assert_rc 1 "非 http(s) 注册表被拒绝"
assert_output_contains "需要 http(s):// 开头的 URL" "错误说明协议要求"

run_dshctl --dry-run --plugin-update --plugin-registry 'https://a b'
assert_rc 1 "含空白的注册表被拒绝"
assert_output_contains "不能包含空白字符" "错误说明空白字符"

run_dshctl --dry-run --plugin-update --plugin-registry 'https://registry.npmjs.org/?x=1'
assert_rc 1 "带查询串的注册表被拒绝"
assert_output_contains "不支持查询串或片段" "错误说明查询串限制"

run_dshctl --dry-run --plugin-update --plugin-registry ''
assert_rc 1 "空注册表被拒绝"
assert_output_contains "缺少注册表 URL" "错误说明缺少取值"

run_dshctl --dry-run --plugin-list --plugin-registry "$REG"
assert_rc 1 "--plugin-list 不接受注册表"
assert_output_contains "仅支持 --plugin-add / --plugin-update / --plugin-repair" \
  "错误说明仅限的操作"

run_dshctl --dry-run --plugin-remove some-plugin --plugin-registry "$REG"
assert_rc 1 "--plugin-remove 不接受注册表"
assert_output_contains "仅支持 --plugin-add" "remove 被明确拒绝"

run_dshctl --install --dry-run --plugin-registry "$REG"
assert_rc 1 "--install 不接受注册表"
assert_output_contains "不能与 install 操作一起使用" "错误说明模式冲突"

finish
