#!/usr/bin/env bash
# 源码声明的 Node 要求（package.json → engines.node）
# 背景：node_ok 只能给出引导下界（22.19+ / 24+），而 master 已要求 >=24.9.0，
#       旧逻辑会在“已满足要求”的提示下让 Node 22/24.0 用户继续安装。

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

# ---------- 单元：按行区间抽取被测函数 ----------
extract_fn() { sed -n "/^$1() {/,/^}/p" "$DSHCTL"; }

for fn in version_ge node_ver_pad node_spec_ok node_range_satisfied repo_node_engines check_repo_node_engines; do
  fn_src="$(extract_fn "$fn")"
  assert_command "能从 dshctl.sh 抽取 $fn" test -n "$fn_src"
  eval "$fn_src"
done
assert_command "node_range_satisfied 已定义" declare -F node_range_satisfied

# ---------- 归一化 ----------
pad() { node_ver_pad "$1" 2>/dev/null || printf 'ERR'; }
assert_equals "$(pad 24.9)" "24.9.0" "两段版本补全为三段"
assert_equals "$(pad 24)" "24.0.0" "单段版本补全"
assert_equals "$(pad v22.19.0)" "22.19.0" "去掉 v 前缀"
assert_equals "$(pad 24.x)" "ERR" "非法版本返回错误"
assert_equals "$(pad '')" "ERR" "空版本返回错误"

# ---------- range 判定 ----------
sat() { # 输出 yes / no / unknown
  if node_range_satisfied "$1" "$2"; then
    printf 'yes'
  else
    local rc=$?
    if [ "$rc" -eq 2 ]; then printf 'unknown'; else printf 'no'; fi
  fi
}

assert_equals "$(sat 24.19.0 '>=24.9.0')" "yes" ">= 命中（更高版本）"
assert_equals "$(sat 24.9.0 '>=24.9.0')" "yes" ">= 命中（恰好等于）"
assert_equals "$(sat 24.8.9 '>=24.9.0')" "no"  ">= 未命中（差一个补丁号）"
assert_equals "$(sat 22.19.0 '>=24.9.0')" "no"  "master 的 >=24.9.0 不接受 Node 22"
assert_equals "$(sat v24.19.0 '>=24.9.0')" "yes" "带 v 前缀的运行时版本也能判定"

assert_equals "$(sat 22.19.0 '^22.19.0 || >=24.0.0')" "yes" "rc.3 双分支：Node 22.19 命中左分支"
assert_equals "$(sat 22.19.9 '^22.19.0 || >=24.0.0')" "yes" "rc.3 双分支：22.19.x 命中左分支"
assert_equals "$(sat 22.18.0 '^22.19.0 || >=24.0.0')" "no"  "rc.3 双分支：22.18 不命中"
assert_equals "$(sat 23.5.0 '^22.19.0 || >=24.0.0')" "no"  "rc.3 双分支：23.x 不命中（caret 上界）"
assert_equals "$(sat 24.0.0 '^22.19.0 || >=24.0.0')" "yes" "rc.3 双分支：24.0 命中右分支"
assert_equals "$(sat 25.0.0 '^22.19.0 || >=24.0.0')" "yes" "rc.3 双分支：25.0 命中右分支"

assert_equals "$(sat 24.9.0 '~24.9.0')" "yes" "~ 命中同一次版本"
assert_equals "$(sat 24.9.7 '~24.9.0')" "yes" "~ 命中同次版本内的补丁号"
assert_equals "$(sat 24.10.0 '~24.9.0')" "no"  "~ 上界拒绝下一个次版本"
assert_equals "$(sat 24.99.0 '^24.9.0')" "yes" "^ 命中同一主版本"
assert_equals "$(sat 25.0.0 '^24.9.0')" "no"  "^ 上界拒绝下一个主版本"
assert_equals "$(sat 0.2.9 '^0.2.1')" "yes"  "0.x 的 caret 上界为次版本"
assert_equals "$(sat 0.3.0 '^0.2.1')" "no"   "0.3.0 超出 ^0.2.1"
assert_equals "$(sat 0.0.4 '^0.0.3')" "no"   "0.0.x 的 caret 上界为补丁号"

assert_equals "$(sat 24.9.1 '>24.9.0')" "yes"  "> 严格大于"
assert_equals "$(sat 24.9.0 '>24.9.0')" "no"   "> 不接受相等"
assert_equals "$(sat 24.9.0 '<=24.9.0')" "yes" "<= 接受相等"
assert_equals "$(sat 24.9.1 '<=24.9.0')" "no"  "<= 拒绝更大版本"
assert_equals "$(sat 24.8.0 '<24.9.0')" "yes"  "< 严格小于"
assert_equals "$(sat 24.9.0 '<24.9.0')" "no"   "< 不接受相等"
assert_equals "$(sat 24.9.0 '=24.9.0')" "yes"  "= 精确匹配"
assert_equals "$(sat 24.9.1 '=24.9.0')" "no"   "= 拒绝近似版本"
assert_equals "$(sat 24.9.0 '24.9.0')" "yes"   "裸版本按等值处理"

assert_equals "$(sat 22.19.3 '>=22.19')" "yes" "两段下界按 .0 补全"
assert_equals "$(sat 22.18.9 '>=22.19')" "no"  "两段下界仍拒绝更低版本"
assert_equals "$(sat 24.19.0 '>=24.9.0, <25')" "yes" "逗号分隔的复合约束"
assert_equals "$(sat 25.1.0 '>=24.9.0, <25')" "no"   "复合约束的右半部分生效"
assert_equals "$(sat 24.19.0 '>=24.9.0  ||  <20')" "yes" "多余空格不影响解析"
assert_equals "$(sat 24.19.0 '*')" "yes" "通配 * 恒满足"
assert_equals "$(sat 24.19.0 '')" "yes" "空 range 视为无约束"
assert_equals "$(sat 24.19.0 '24.x')" "unknown" "通配段写法标记为无法解析"
assert_equals "$(sat 24.19.0 '>=x')" "unknown" "非数字下界标记为无法解析"

# ---------- 从 package.json 读取 engines.node ----------
DSH_DIR="$TEST_HOME/engines-fixture"
mkdir -p "$DSH_DIR"
write_pkg() { printf '%s\n' "$1" > "$DSH_DIR/package.json"; }
eng() { if repo_node_engines; then :; else printf 'ERR'; fi; }

write_pkg '{"name":"x","engines":{"node":">=24.9.0"}}'
assert_equals "$(eng)" ">=24.9.0" "读取字符串写法"

write_pkg '{"name":"x","engines":{"node":["^22.19.0",">=24.0.0"]}}'
assert_equals "$(eng)" "^22.19.0 || >=24.0.0" "数组写法按 || 合并"

write_pkg '{"name":"x"}'
assert_equals "$(eng)" "ERR" "未声明 engines 时返回错误"

write_pkg '{"name":"x","engines":{"node":""}}'
assert_equals "$(eng)" "ERR" "空声明时返回错误"

write_pkg '{not json'
assert_equals "$(eng)" "ERR" "JSON 损坏时返回错误"

rm -f "$DSH_DIR/package.json"
assert_equals "$(eng)" "ERR" "package.json 不存在时返回错误"

# ---------- 校验函数的结论分支 ----------
DSH_DIR="$TEST_HOME/engines-check"
DSH_NODE_MAJOR="${DSH_NODE_MAJOR:-24}"
mkdir -p "$DSH_DIR"
node_ver() { printf 'v%s' "$STUB_NODE_VER"; }
ok()   { printf 'OK %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; return 1; }

printf '{"name":"x","engines":{"node":">=24.9.0"}}\n' > "$DSH_DIR/package.json"
STUB_NODE_VER="22.19.0"
check_out="$(check_repo_node_engines)"
assert_command "Node 22 面对 >=24.9.0 时给出告警" \
  grep -qF "源码要求 Node.js >=24.9.0" <<< "$check_out"
assert_command "告警包含当前版本" grep -qF "当前为 v22.19.0" <<< "$check_out"
assert_command "告警给出升级指引" grep -qF "nvm install" <<< "$check_out"

STUB_NODE_VER="24.19.0"
check_out="$(check_repo_node_engines)"
assert_command "满足时输出成功结论" grep -qF "满足源码要求" <<< "$check_out"
assert_command "成功结论带上 engines 原文" grep -qF "engines.node: >=24.9.0" <<< "$check_out"

STUB_NODE_VER="24.19.0"
printf '{"name":"x","engines":{"node":"24.x"}}\n' > "$DSH_DIR/package.json"
check_out="$(check_repo_node_engines)"
assert_command "无法解析的 range 只告警不阻断" grep -qF "无法解析" <<< "$check_out"
assert_command "无法解析时不输出成功结论" bash -c '! grep -qF "满足源码要求" <<< "$1"' _ "$check_out"

# ---------- 集成：--install --dry-run 展示源码要求 ----------
REAL_NODE="$(command -v node 2>/dev/null || true)"
if [ -n "$REAL_NODE" ]; then
  # 用真实 node 替换 stub，让 repo_node_engines 能解析 fixture
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$REAL_NODE" > "$FAKE_BIN/node"
  chmod 0755 "$FAKE_BIN/node"

  FAKE_REPO="$TEST_HOME/deepseek-harness"
  mkdir -p "$FAKE_REPO"
  printf '{"name":"x","engines":{"node":">=24.9.0"}}\n' > "$FAKE_REPO/package.json"
  run_dshctl --install --dry-run
  assert_rc 0 "声明 engines 时 --install --dry-run 退出码为 0"
  assert_stdout_contains "Node.js >=24.9.0" "dry-run 展示源码要求"
  assert_stdout_contains "engines.node" "dry-run 标注要求来源"

  printf '{"name":"x"}\n' > "$FAKE_REPO/package.json"
  run_dshctl --install --dry-run
  assert_rc 0 "未声明 engines 时 --install --dry-run 退出码为 0"
  assert_stdout_not_contains "源码要求" "未声明 engines 时不输出源码要求"
else
  printf '# 未找到 node，跳过 dry-run 集成断言\n'
fi

# ---------- 接线：主流程在获取源码后校验 ----------
assert_command "安装主流程调用 check_repo_node_engines" \
  grep -qxF '  check_repo_node_engines' "$DSHCTL"
assert_command "engines 校验位于 ensure_repo 之后" \
  awk '/^  ensure_repo$/{r=NR} /^  check_repo_node_engines$/{c=NR} END{exit !(r && c && c > r)}' "$DSHCTL"

finish
