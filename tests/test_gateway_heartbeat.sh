#!/usr/bin/env bash
# gateway 心跳参数：通过 dshctl 读写 profile 的 cordis.patch.yml
#   --gateway-heartbeat         查看当前值（只读）
#   --gateway-heartbeat-set MS  设置（毫秒，1..2147483647）
#   --gateway-heartbeat-reset   移除，回落 dsh 默认值

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

DSH_FAKE="$TEST_HOME/deepseek-harness"
PROFILE_DIR="$TEST_HOME/.dsh/profiles/web"
PATCH="$PROFILE_DIR/cordis.patch.yml"
mkdir -p "$DSH_FAKE/apps/cli" "$PROFILE_DIR"
printf '{"name":"@deepseek-ai/dsh","version":"0.2.1"}\n' > "$DSH_FAKE/apps/cli/package.json"

bak_count() { ls -1 "$PATCH".bak.* 2>/dev/null | wc -l | tr -d ' '; }

# ---------- 查看：无显式设置 ----------
printf '# user patch\n[]\n' > "$PATCH"
run_dshctl --gateway-heartbeat
assert_rc 0 "无设置时 --gateway-heartbeat 退出码为 0"
assert_stdout_contains "2000" "显示 dsh 默认值 2000ms"
assert_stdout_contains "未显式设置" "标注尚未显式设置"
assert_stdout_contains "取值范围" "说明合法取值范围"

# ---------- 设置：写入新条目 ----------
run_dshctl --gateway-heartbeat-set 30000 -y
assert_rc 0 "--gateway-heartbeat-set 退出码为 0"
assert_command "写入 id: typert-gateway" grep -qF "id: typert-gateway" "$PATCH"
assert_command "写入 websocketHeartbeatIntervalMs: 30000" \
  grep -qF "websocketHeartbeatIntervalMs: 30000" "$PATCH"
assert_equals "$(bak_count)" "1" "修改前生成备份"
assert_stdout_contains "重启" "提示需要重启生效"

# ---------- 查看：显示已设置值 ----------
run_dshctl --gateway-heartbeat
assert_rc 0 "已设置时 --gateway-heartbeat 退出码为 0"
assert_stdout_contains "30000" "显示已设置的 30000"
assert_stdout_contains "60000" "显示容忍窗口 60000"

# ---------- 设置：保留其他条目与已有键 ----------
cat > "$PATCH" <<'EOF'
# user patch
- id: llm-deepseek
  name: '@deepseek-ai/dsh-llm-deepseek-api-key'
  config:
    apiKeyEnv: DEEPSEEK_API_KEY
- id: typert-gateway
  name: '@deepseek-ai/dsh-api-gateway'
  config:
    streamInboxBytes: 262144
- id: webserver
  config:
    host: '127.0.0.1'
EOF
run_dshctl --gateway-heartbeat-set 45000 -y
assert_rc 0 "已有 gateway 条目时设置退出码为 0"
assert_command "保留同层其他键 streamInboxBytes" grep -qF "streamInboxBytes: 262144" "$PATCH"
assert_command "写入新心跳值" grep -qF "websocketHeartbeatIntervalMs: 45000" "$PATCH"
assert_command "保留 llm-deepseek 条目" grep -qF "apiKeyEnv: DEEPSEEK_API_KEY" "$PATCH"
assert_command "保留 webserver 条目" grep -qF "id: webserver" "$PATCH"
assert_equals "$(grep -c 'id: typert-gateway' "$PATCH")" "1" "gateway 条目未被重复添加"

# ---------- 修改：替换旧值而非追加 ----------
run_dshctl --gateway-heartbeat-set 60000 -y
assert_rc 0 "重复设置退出码为 0"
assert_command "旧值 45000 已被替换" \
  bash -c "! grep -qF 'websocketHeartbeatIntervalMs: 45000' '$PATCH'"
assert_command "新值 60000 已写入" grep -qF "websocketHeartbeatIntervalMs: 60000" "$PATCH"
assert_equals "$(grep -c 'websocketHeartbeatIntervalMs' "$PATCH")" "1" "心跳键没有重复行"

# ---------- 嵌套同名字段不被误伤 ----------
cat > "$PATCH" <<'EOF'
- id: typert-gateway
  config:
    models:
      - id: nested-key
        websocketHeartbeatIntervalMs: 999
    websocketHeartbeatIntervalMs: 7000
EOF
run_dshctl --gateway-heartbeat-set 8000 -y
assert_rc 0 "存在嵌套同名键时设置退出码为 0"
assert_command "只改直接子键" grep -qF "websocketHeartbeatIntervalMs: 8000" "$PATCH"
assert_command "嵌套层同名键保持不变" grep -qF "websocketHeartbeatIntervalMs: 999" "$PATCH"

# ---------- 非法值 ----------
run_dshctl --gateway-heartbeat-set 0 -y
assert_rc 1 "0 被拒绝（低于下限）"
run_dshctl --gateway-heartbeat-set abc -y
assert_rc 1 "非数字被拒绝"
run_dshctl --gateway-heartbeat-set 2147483648 -y
assert_rc 1 "2147483648 被拒绝（超过上限）"
run_dshctl --gateway-heartbeat-set 1 -y
assert_rc 0 "边界值 1 被接受"
run_dshctl --gateway-heartbeat-set 2147483647 -y
assert_rc 0 "边界值 2147483647 被接受"

# ---------- 重置 ----------
cat > "$PATCH" <<'EOF'
- id: typert-gateway
  config:
    streamInboxBytes: 262144
    websocketHeartbeatIntervalMs: 60000
EOF
run_dshctl --gateway-heartbeat-reset -y
assert_rc 0 "--gateway-heartbeat-reset 退出码为 0"
assert_command "心跳键已移除" bash -c "! grep -qF 'websocketHeartbeatIntervalMs' '$PATCH'"
assert_command "同层其他键仍保留" grep -qF "streamInboxBytes: 262144" "$PATCH"
run_dshctl --gateway-heartbeat
assert_stdout_contains "2000" "重置后回落到默认 2000"

# ---------- 互斥与参数校验 ----------
run_dshctl --gateway-heartbeat --status
assert_rc 1 "查看与 --status 互斥"
run_dshctl --gateway-heartbeat-set 5000 --gateway-heartbeat-reset -y
assert_rc 1 "set 与 reset 互斥"
run_dshctl --gateway-heartbeat-set
assert_rc 1 "set 缺少数值时被拒绝"

finish
