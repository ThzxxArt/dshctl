#!/usr/bin/env bash
# 版本比较：version_ge 的 semver 预发布优先级，以及 --upgrade-check 的结论行
# 背景：dsh 0.2.1 系列按 0.2.1-alpha.N → 0.2.1-rc.N → 正式版推进，
# 旧实现忽略预发布后缀，会把 0.2.1-alpha.5 判成不低于 0.2.1-rc.2（漏报升级）。

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

# ---------- 单元：直接从脚本提取 version_ge ----------
unit_src="$(sed -n '/^version_ge() {/,/^}/p' "$DSHCTL")"
assert_command "能从 dshctl.sh 提取 version_ge" test -n "$unit_src"
eval "$unit_src"
assert_command "version_ge 已定义" declare -F version_ge

ge() { if version_ge "$1" "$2"; then printf 'yes'; else printf 'no'; fi; }

assert_equals "$(ge 0.2.1-rc.2 0.2.1-alpha.5)" "yes" "rc.2 >= alpha.5"
assert_equals "$(ge 0.2.1-alpha.5 0.2.1-rc.2)" "no"  "alpha.5 不再被判为不低于 rc.2"
assert_equals "$(ge 0.2.1-rc.2 0.2.1-rc.1)" "yes" "rc.2 >= rc.1"
assert_equals "$(ge 0.2.1-rc.1 0.2.1-rc.2)" "no"  "rc.1 < rc.2"
assert_equals "$(ge 0.2.1 0.2.1-rc.2)" "yes" "正式版 >= 预发布版"
assert_equals "$(ge 0.2.1-rc.2 0.2.1)" "no"  "预发布版 < 正式版"
assert_equals "$(ge 0.2.1-rc.2 0.2.1-beta.9)" "yes" "rc > beta"
assert_equals "$(ge 0.2.1-alpha.10 0.2.1-alpha.9)" "yes" "alpha.10 > alpha.9（数字标识符按数值）"
assert_equals "$(ge 0.2.1-alpha.9 0.2.1-alpha.10)" "no"  "alpha.9 < alpha.10"
assert_equals "$(ge 0.2.1-rc.1 0.2.1-rc)" "yes" "rc.1 > rc（标识符多者更大）"
assert_equals "$(ge 0.2.1-rc 0.2.1-rc.1)" "no"  "rc < rc.1"
assert_equals "$(ge 0.2.1-rc.2 0.2.1-rc.2)" "yes" "相同版本视为不低于"
assert_equals "$(ge 0.2.1-rc.2 0.2.0-rc.2)" "yes" "0.2.1 > 0.2.0"
assert_equals "$(ge 0.2.0-rc.2 0.2.1-rc.2)" "no"  "0.2.0 < 0.2.1"
assert_equals "$(ge 0.2.1-alpha.5 0.2.1-alpha.5)" "yes" "相同预发布版本视为不低于"

# ---------- 端到端：--upgrade-check 的结论行（stub git，不触网） ----------
DSH_FAKE="$TEST_HOME/deepseek-harness"
mkdir -p "$DSH_FAKE/apps/cli" "$DSH_FAKE/.git"

set_local_version() {
  printf '{"name":"@deepseek-ai/dsh","version":"%s"}\n' "$1" > "$DSH_FAKE/apps/cli/package.json"
}

# 上游 tag 由 fixture 提供；同时写入 peeled 行（^{}）验证过滤
emit_tags() {
  : > "$FAKE_BIN/upstream-tags.txt"
  local i=0 t
  for t in "$@"; do
    i=$((i + 1))
    printf 'sha%02d\trefs/tags/%s\n' "$i" "$t" >> "$FAKE_BIN/upstream-tags.txt"
    printf 'peel%02d\trefs/tags/%s^{}\n' "$i" "$t" >> "$FAKE_BIN/upstream-tags.txt"
  done
}

make_stub "$FAKE_BIN/git" '#!/usr/bin/env bash
self_dir="$(dirname "$0")"
case "$*" in
  *"ls-remote --tags"*)
    if [ -f "$self_dir/upstream-tags.txt" ]; then cat "$self_dir/upstream-tags.txt"; fi
    ;;
  *"ls-remote origin HEAD"*)
    printf "%s\tHEAD\n" "abcabcabcabcabcabcabcabcabcabcabcabcabca"
    ;;
  *"rev-parse --short HEAD"*)
    printf "%s\n" "abcabca"
    ;;
  *"rev-parse HEAD"*)
    printf "%s\n" "abcabcabcabcabcabcabcabcabcabcabcabcabca"
    ;;
  *)
    exit 0
    ;;
esac'

# 1) 本地 alpha.5，上游已到 rc.2：必须提示可升级
emit_tags dsh-v0.2.1-alpha.5 dsh-v0.2.1-rc.1 dsh-v0.2.1-rc.2
set_local_version 0.2.1-alpha.5
run_dshctl --upgrade-check
assert_rc 0 "alpha.5 上 --upgrade-check 退出码为 0"
assert_stdout_contains "本地 dsh   : 0.2.1-alpha.5" "读取本地 dsh 版本"
assert_stdout_contains "上游最新tag: dsh-v0.2.1-rc.2" "选中上游最新 tag（剔除 peeled tag）"
assert_stdout_contains "上游有更新版本" "alpha.5 < rc.2：提示可升级"
assert_stdout_not_contains "本地不低于上游最新 tag" "不再误报「本地已是最新」"

# 2) 本地已是上游最新 rc.2
set_local_version 0.2.1-rc.2
run_dshctl --upgrade-check
assert_rc 0 "rc.2 上 --upgrade-check 退出码为 0"
assert_stdout_contains "本地不低于上游最新 tag" "rc.2 与上游 rc.2 相同：判为不低于"
assert_stdout_not_contains "上游有更新版本" "同版本不再提示升级"

# 3) 预发布序号两位数：按字符串定序会误选 alpha.9
emit_tags dsh-v0.2.1-alpha.9 dsh-v0.2.1-alpha.10
set_local_version 0.2.1-alpha.9
run_dshctl --upgrade-check
assert_rc 0 "alpha.9 上 --upgrade-check 退出码为 0"
assert_stdout_contains "上游最新tag: dsh-v0.2.1-alpha.10" "tag 定序按数值取 alpha.10（非字符串序）"
assert_stdout_contains "上游有更新版本" "alpha.9 < alpha.10：提示可升级"

finish
