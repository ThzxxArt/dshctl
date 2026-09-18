#!/usr/bin/env bash
# 测试公共库：隔离 HOME、断言与结果统计
# 兼容 Bash 3.2（macOS 自带版本），不依赖任何外部测试框架。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DSHCTL="$PROJECT_ROOT/dshctl.sh"

TEST_HOME=""
FAKE_BIN=""
OUT_FILE=""
ERR_FILE=""
LAST_RC=0
TOTAL=0
FAILED=0

make_stub() { # $1=路径 $2=脚本内容
  printf '%s\n' "$2" > "$1"
  chmod 0755 "$1"
}

# 创建隔离环境：临时 HOME / DSH_DIR / DSH_HOME，以及伪造的 node、pnpm，
# 保证断言可预测且不触网（真实 Node/pnpm 版本随机器变化）。
setup() {
  TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dshctl-test.XXXXXX")" || {
    echo "无法创建临时目录" >&2
    exit 1
  }
  FAKE_BIN="$TEST_HOME/fakebin"
  mkdir -p "$FAKE_BIN"
  make_stub "$FAKE_BIN/node" '#!/usr/bin/env bash
echo "v24.19.0"'
  make_stub "$FAKE_BIN/pnpm" '#!/usr/bin/env bash
echo "11.7.0"'
  OUT_FILE="$TEST_HOME/stdout.txt"
  ERR_FILE="$TEST_HOME/stderr.txt"
  LAST_RC=0
}

teardown() {
  [ -n "${TEST_HOME:-}" ] || return 0
  rm -rf -- "$TEST_HOME"
  TEST_HOME=""
}

# 清空可能从外部环境泄漏的配置，保证测试与开发者机器状态无关
sanitize_env() {
  unset DSH_REPO_URL DSH_REF DSH_DIR DSH_NODE_MAJOR DSH_PNPM_FALLBACK DSH_HOST DSH_PORT \
    DSH_API_KEY DSH_BASE_URL DSH_GIT_PROXY GIT_PROXY DSH_GITHUB_MIRROR DSH_PROXY_SCOPE \
    DSH_NO_PROXY DSH_NPM_MIRROR DSH_NODE_MIRROR DSH_LOG_FILE DSH_LOG_MAX_MB \
    DSH_WEB_LAN_PATCH DSH_HOME 2>/dev/null || true
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true
}

# 在完全隔离的环境中运行 dshctl：env -i 清空继承变量，仅保留最小 PATH 与临时 HOME
run_dshctl() {
  sanitize_env
  LAST_RC=0
  env -i \
    HOME="$TEST_HOME" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    LC_ALL=C \
    TMPDIR="${TMPDIR:-/tmp}" \
    DSH_DIR="$TEST_HOME/deepseek-harness" \
    DSH_HOME="$TEST_HOME/.dsh" \
    DSH_LOG_FILE="$TEST_HOME/dshctl.log" \
    bash "$DSHCTL" "$@" >"$OUT_FILE" 2>"$ERR_FILE" || LAST_RC=$?
  return 0
}

_pass() { TOTAL=$((TOTAL + 1)); printf 'ok %d - %s\n' "$TOTAL" "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1)); printf 'not ok %d - %s\n' "$TOTAL" "$1"; }

assert_rc() {
  local expected="$1" desc="${2:-退出码}"
  if [ "$LAST_RC" -eq "$expected" ]; then
    _pass "$desc（rc=$LAST_RC）"
  else
    _fail "$desc：期望 rc=$expected，实际 rc=$LAST_RC"
  fi
}

assert_stdout_contains() {
  local pattern="$1"
  local desc="${2:-stdout 包含 [$pattern]}"
  if [ -f "$OUT_FILE" ] && grep -qF -- "$pattern" "$OUT_FILE"; then
    _pass "$desc"
  else
    _fail "$desc（stdout 中未找到）"
  fi
}

assert_stdout_not_contains() {
  local pattern="$1"
  local desc="${2:-stdout 不包含 [$pattern]}"
  if [ -f "$OUT_FILE" ] && grep -qF -- "$pattern" "$OUT_FILE"; then
    _fail "$desc（stdout 中意外出现）"
  else
    _pass "$desc"
  fi
}

# 说明：dshctl 的日志管道会把 stdout/stderr 一并写入日志，并经 tee 回显到原始 stdout，
# 因此错误提示的实际落点通常是 stdout 捕获文件；这里同时检查两个流，
# 让断言不依赖内部日志实现细节。
assert_output_contains() {
  local pattern="$1"
  local desc="${2:-输出包含 [$pattern]}"
  if { [ -f "$OUT_FILE" ] && grep -qF -- "$pattern" "$OUT_FILE"; } \
    || { [ -f "$ERR_FILE" ] && grep -qF -- "$pattern" "$ERR_FILE"; }; then
    _pass "$desc"
  else
    _fail "$desc（stdout/stderr 中均未找到）"
  fi
}

assert_file_exists() {
  local path="$1"
  local desc="${2:-文件存在: $path}"
  if [ -e "$path" ]; then _pass "$desc"; else _fail "$desc（不存在）"; fi
}

assert_file_absent() {
  local path="$1"
  local desc="${2:-文件不存在: $path}"
  if [ -e "$path" ]; then _fail "$desc（意外存在）"; else _pass "$desc"; fi
}

assert_symlink_to() {
  local link="$1" target="$2"
  local desc="${3:-软链 $link -> $target}"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    _pass "$desc"
  else
    _fail "$desc（当前: $(readlink "$link" 2>/dev/null || echo '非软链或不存在')）"
  fi
}

assert_equals() {
  local actual="$1" expected="$2" desc="${3:-值相等}"
  if [ "$actual" = "$expected" ]; then
    _pass "$desc"
  else
    _fail "$desc：期望 [$expected]，实际 [$actual]"
  fi
}

# $1=描述，其余为命令；命令成功则通过
assert_command() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then _pass "$desc"; else _fail "$desc"; fi
}

finish() {
  printf '# %d 个断言，%d 个失败\n' "$TOTAL" "$FAILED"
  if [ "$FAILED" -gt 0 ]; then exit 1; fi
  exit 0
}
