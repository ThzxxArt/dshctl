#!/usr/bin/env bash
# 模型配置读写：dsh 0.1.7+ 写入 profile 的 cordis.patch.yml；≤0.1.6 写 settings.yaml

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

DSH_FAKE="$TEST_HOME/deepseek-harness"
PROFILE_DIR="$TEST_HOME/.dsh/profiles/web"
PATCH="$PROFILE_DIR/cordis.patch.yml"
mkdir -p "$DSH_FAKE/apps/cli" "$PROFILE_DIR"

set_dsh_version() {
  printf '{"name":"@deepseek-ai/dsh","version":"%s"}\n' "$1" > "$DSH_FAKE/apps/cli/package.json"
}

bak_count() {
  ls -1 "$PATCH".bak.* 2>/dev/null | wc -l | tr -d ' '
}

# ---------- 0.2.0：读取 profile patch ----------
set_dsh_version "0.2.0-rc.2"
cat > "$PATCH" <<'EOF'
# user patch
- id: llm-deepseek
  name: '@deepseek-ai/dsh-llm-deepseek-api-key'
  config:
    apiKeyEnv: DEEPSEEK_API_KEY
    baseURL: https://gw.example.com/anthropic
    protocol: chat-completions
- id: webserver
  config:
    host: '127.0.0.1'
EOF

run_dshctl --model-show
assert_rc 0 "0.2.0 下 --model-show 退出码为 0"
assert_stdout_contains "https://gw.example.com/anthropic" "展示 profile 配置中的 baseURL"
assert_stdout_contains "profile 配置" "标注来源为 profile 配置"
assert_stdout_contains "protocol=chat-completions" "提示残留 protocol 字段"
assert_stdout_contains "配置位置" "展示配置落盘位置"

# ---------- 0.2.0：更新 baseURL，保留其他键与条目 ----------
run_dshctl --model-set-base https://api.deepseek.com/anthropic -y
assert_rc 0 "0.2.0 下 --model-set-base 退出码为 0"
assert_command "patch 含新 baseURL" grep -qF "baseURL: https://api.deepseek.com/anthropic" "$PATCH"
assert_command "保留 apiKeyEnv" grep -qF "apiKeyEnv: DEEPSEEK_API_KEY" "$PATCH"
assert_command "保留 webserver 条目" grep -qF "id: webserver" "$PATCH"
assert_command "旧 baseURL 已被替换" bash -c "! grep -qF 'gw.example.com' '$PATCH'"
assert_equals "$(bak_count)" "1" "修改前生成备份"

# ---------- 0.2.0：空 patch 模板 [] ----------
printf '# user patch\n[]\n' > "$PATCH"
run_dshctl --model-set-base https://a.example.com/anthropic -y
assert_rc 0 "[] 模板下 --model-set-base 退出码为 0"
assert_command "[] 模板被替换" bash -c "! grep -qE '^\[[[:space:]]*\]$' '$PATCH'"
assert_command "新条目已写入" grep -qF "baseURL: https://a.example.com/anthropic" "$PATCH"

# ---------- 0.2.0：无 llm 条目时追加 ----------
printf -- "- id: webserver\n  config:\n    host: '127.0.0.1'\n" > "$PATCH"
run_dshctl --model-set-base https://b.example.com -y
assert_command "追加 llm-deepseek 条目" grep -qF "id: llm-deepseek" "$PATCH"
assert_command "保留原 webserver 条目" grep -qF "id: webserver" "$PATCH"

# ---------- 0.2.0：--model-fix 移除 protocol 字段 ----------
cat > "$PATCH" <<'EOF'
- id: llm-deepseek
  config:
    apiKeyEnv: DEEPSEEK_API_KEY
    baseURL: https://c.example.com
    protocol: messages
EOF
run_dshctl --model-fix -y
assert_rc 0 "0.2.0 下 --model-fix 退出码为 0"
assert_command "protocol 字段已移除" bash -c "! grep -qF 'protocol' '$PATCH'"
assert_command "baseURL 保留" grep -qF "https://c.example.com" "$PATCH"
assert_command "apiKeyEnv 保留" grep -qF "apiKeyEnv: DEEPSEEK_API_KEY" "$PATCH"

# ---------- 0.2.0：配置无违规时无需修复 ----------
printf -- "- id: llm-deepseek\n  config:\n    baseURL: https://api.deepseek.com/anthropic\n" > "$PATCH"
run_dshctl --model-fix -y
assert_rc 0 "无违规时 --model-fix 退出码为 0"
assert_stdout_contains "无需修复" "无违规时提示无需修复"

# ---------- 0.2.0：非交互缺少 -y 时拒绝写配置 ----------
run_dshctl --model-set-base https://need-yes.example.com
assert_rc 1 "非交互环境修改配置需要 -y"
assert_output_contains "需要 -y 确认" "非交互缺少 -y 的提示"

# ---------- 0.2.0：非法 URL ----------
run_dshctl --model-set-base ftp://bad.example.com -y
assert_rc 1 "非 http(s) 地址被拒绝"

# ---------- ≤0.1.6：仍写 settings.yaml，不碰 patch ----------
set_dsh_version "0.1.6-alpha.2"
rm -f "$TEST_HOME/.dsh/settings.yaml"
printf -- "- id: llm-deepseek\n  config:\n    baseURL: https://keep.example.com\n" > "$PATCH"
run_dshctl --model-set-base https://legacy.example.com -y
assert_rc 0 "0.1.6 下 --model-set-base 退出码为 0"
assert_file_exists "$TEST_HOME/.dsh/settings.yaml" "0.1.6 写入 settings.yaml"
assert_command "settings.yaml 含新地址" grep -qF "baseURL: https://legacy.example.com" "$TEST_HOME/.dsh/settings.yaml"
assert_command "0.1.6 不改 profile patch" grep -qF "https://keep.example.com" "$PATCH"

run_dshctl --model-show
assert_rc 0 "0.1.6 下 --model-show 退出码为 0"
assert_stdout_contains "https://legacy.example.com" "0.1.6 从 settings.yaml 读取地址"

# ---------- .env 非法项：--model-fix 自动注释 ----------
printf 'DEEPSEEK_BASE_URL=https://api.deepseek.com\n' > "$DSH_FAKE/.env"
run_dshctl --model-fix -y
assert_rc 0 "存在 .env 非法项时 --model-fix 退出码为 0"
assert_command ".env 非法项被注释" grep -qF "# DEEPSEEK_BASE_URL=" "$DSH_FAKE/.env"

finish
