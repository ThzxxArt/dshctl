#!/usr/bin/env bash
# Web 访问能力：--host / --web-lan / --public-url / --tls-cert / --tls-key
# 以及按 dsh 版本的绑定分流（0.2.1-alpha.2+ 拒绝通配地址）

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

# ---------- help 列出新选项 ----------
run_dshctl --help
assert_rc 0 "--help 退出码为 0"
assert_stdout_contains "--public-url" "--help 列出 --public-url"
assert_stdout_contains "--tls-cert" "--help 列出 --tls-cert"
assert_stdout_contains "--tls-key" "--help 列出 --tls-key"

# ---------- 参数校验 ----------
run_dshctl --install --dry-run --public-url ftp://bad.example/
assert_rc 1 "非 http(s) 的 --public-url 被拒绝"
assert_output_contains "http:// 或 https://" "public-url 协议提示"

run_dshctl --install --dry-run --tls-cert /tmp/only-cert.pem
assert_rc 1 "--tls-cert 缺少 --tls-key 被拒绝"
assert_output_contains "成对" "tls 成对提示"

run_dshctl --install --dry-run --host not-an-ip
assert_rc 1 "非法的 --host 取值被拒绝"
assert_output_contains "--host 只接受" "host 字面量提示"

run_dshctl --status --public-url https://dsh.example/
assert_rc 1 "--public-url 不能用于 --status"
assert_output_contains "不能与" "public-url 模式校验提示"

# ---------- dry-run 展示新能力 ----------
run_dshctl --install --dry-run --web-lan --public-url https://dsh.example/ \
  --tls-cert /tmp/chain.pem --tls-key /tmp/key.pem --trusted-host dsh.example
assert_rc 0 "带新选项的 dry-run 退出码为 0"
assert_stdout_contains "对外地址" "dry-run 展示对外地址"
assert_stdout_contains "原生 HTTPS" "dry-run 展示原生 HTTPS"
assert_stdout_contains "信任主机" "dry-run 展示信任主机"

# ---------- --port 0 在 dry-run 下展示系统分配 ----------
run_dshctl --install --dry-run --port 0
assert_rc 0 "--port 0 dry-run 退出码为 0"

# ---------- 按 dsh 版本的绑定分流 ----------
DSH_FAKE="$TEST_HOME/deepseek-harness"
mkdir -p "$DSH_FAKE/apps/cli"
printf '{"name":"@deepseek-ai/dsh","version":"0.2.1-alpha.4"}\n' > "$DSH_FAKE/apps/cli/package.json"

run_dshctl --install --dry-run --web-lan
assert_rc 0 "0.2.1 下 --web-lan dry-run 退出码为 0"
assert_stdout_contains "自动绑定本机主网卡 IPv4" "0.2.1+ 自动绑定具体网卡"

run_dshctl --install --dry-run --host 192.168.1.5
assert_rc 0 "0.2.1 下 --host 具体 IP dry-run 退出码为 0"
assert_stdout_contains "绑定指定地址 192.168.1.5" "0.2.1+ 支持指定具体 IP"

printf '{"name":"@deepseek-ai/dsh","version":"0.2.0-rc.2"}\n' > "$DSH_FAKE/apps/cli/package.json"
run_dshctl --install --dry-run --web-lan
assert_rc 0 "0.2.0 下 --web-lan dry-run 退出码为 0"
assert_stdout_contains "0.0.0.0 通配补丁" "0.2.0 回退到通配补丁方式"

# ---------- --status 读取启动器标记 ----------
mkdir -p "$TEST_HOME/.local/bin"
cat > "$TEST_HOME/.local/bin/dsh" <<'EOS'
#!/usr/bin/env bash
DSH_HOST_MODE="explicit"
DSH_HOST_BAKED="192.168.1.9"
DSH_HOST="${DSH_HOST:-192.168.1.9}"
DSH_PUBLIC_URL_BAKED="https://dsh.example/"
DSH_TLS_CERT_BAKED="/tmp/chain.pem"
DSH_PUBLIC_URL="${DSH_PUBLIC_URL:-https://dsh.example/}"
EOS
chmod 0755 "$TEST_HOME/.local/bin/dsh"

run_dshctl --status
assert_rc 0 "有启动器标记时 --status 退出码为 0"
assert_stdout_contains "绑定 192.168.1.9" "status 展示绑定的具体地址"
assert_stdout_contains "对外地址" "status 展示对外地址"
assert_stdout_contains "HTTPS" "status 展示 HTTPS"

finish
