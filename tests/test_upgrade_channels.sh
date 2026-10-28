#!/usr/bin/env bash
# 通道化 --upgrade-check：版本通道归类、晋级阶梯、--channel 覆盖与跨通道提示
# 背景：本地 0.2.1-rc.3 时，旧实现把所有 tag 混在一起取「最新」，于是推荐安装
# 0.2.2-alpha.2（下一版本线的 alpha）。rc 与 alpha 是不同发布阶段，不能这样跨线推荐；
# 但同一版本线的 alpha → rc → stable 属正常晋级，必须保留。

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

# ---------- 单元：通道 / 版本线 / 晋级阶梯 ----------
ch_src="$(sed -n '/^version_channel() {/,/^}/p' "$DSHCTL")"
ladder_src="$(sed -n '/^channel_ladder() {/,/^}/p' "$DSHCTL")"
latest_src="$(sed -n '/^latest_tag_in_channels() {/,/^}/p' "$DSHCTL")"
ge_src="$(sed -n '/^version_ge() {/,/^}/p' "$DSHCTL")"

for pair in "version_channel:$ch_src" \
            "channel_ladder:$ladder_src" "latest_tag_in_channels:$latest_src" \
            "version_ge:$ge_src"; do
  fn="${pair%%:*}"
  assert_command "能从 dshctl.sh 提取 $fn" test -n "${pair#*:}"
done
eval "$ch_src"
eval "$ladder_src"
eval "$ge_src"
eval "$latest_src"

assert_equals "$(version_channel 0.2.1-rc.3)" "rc" "0.2.1-rc.3 归入 rc 通道"
assert_equals "$(version_channel 0.2.1)" "stable" "0.2.1 归入 stable 通道"
assert_equals "$(version_channel 0.2.2-alpha.2)" "alpha" "0.2.2-alpha.2 归入 alpha 通道"
assert_equals "$(version_channel 0.2.1-beta.1)" "other" "beta 归入 other 通道"
assert_equals "$(version_channel 0.2.1-rc)" "rc" "无序号 rc 仍归入 rc 通道"

assert_equals "$(channel_ladder stable)" "stable" "stable 只比 stable"
assert_equals "$(channel_ladder rc)" "rc stable" "rc 比 rc/stable"
assert_equals "$(channel_ladder alpha)" "alpha rc stable" "alpha 比 alpha/rc/stable"
assert_equals "$(channel_ladder other)" "stable rc alpha other" "other 不限通道"

UPSTREAM_TAG_CACHE="$(printf '%s\n' 0.2.1-rc.4 0.2.2-alpha.2 0.2.1 0.2.1-beta.1)"
assert_equals "$(latest_tag_in_channels 'rc stable')" "dsh-v0.2.1" "rc 阶梯内正式版高于 rc（晋级后的正式版优先）"
assert_equals "$(latest_tag_in_channels 'stable')" "dsh-v0.2.1" "stable 通道取正式版"
assert_equals "$(latest_tag_in_channels 'rc')" "dsh-v0.2.1-rc.4" "只比 rc 时取 rc.4"
assert_equals "$(latest_tag_in_channels 'alpha rc stable')" "dsh-v0.2.2-alpha.2" "alpha 阶梯内取全通道最新"
assert_equals "$(latest_tag_in_channels 'other')" "dsh-v0.2.1-beta.1" "other 通道可被检索"
UPSTREAM_TAG_CACHE="$(printf '%s\n' 0.2.1-rc.4 0.2.2-alpha.2)"
assert_equals "$(latest_tag_in_channels 'rc stable')" "dsh-v0.2.1-rc.4" "无正式版时 rc 阶梯取 rc.4（排除 alpha）"
# shellcheck disable=SC2034  # 该变量由下方 eval 出来的 latest_tag_in_channels 读取
UPSTREAM_TAG_CACHE=""
assert_equals "$(latest_tag_in_channels 'stable')" "" "缓存为空时返回空（不误报版本）"

# ---------- 端到端：stub git，验证输出与 --channel 覆盖 ----------
DSH_FAKE="$TEST_HOME/deepseek-harness"
mkdir -p "$DSH_FAKE/apps/cli" "$DSH_FAKE/.git"

set_local_version() {
  printf '{"name":"@deepseek-ai/dsh","version":"%s"}\n' "$1" > "$DSH_FAKE/apps/cli/package.json"
}

emit_tags() {
  : > "$FAKE_BIN/upstream-tags.txt"
  : > "$FAKE_BIN/lsremote-count"
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
    printf "call\n" >> "$self_dir/lsremote-count"
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

# 1) rc 线：同线 rc.4 与下一版本线 alpha.2 并存，默认只能推荐 rc.4
emit_tags dsh-v0.2.0 dsh-v0.2.1-rc.3 dsh-v0.2.1-rc.4 dsh-v0.2.2-alpha.2
set_local_version 0.2.1-rc.3
run_dshctl --upgrade-check
assert_rc 0 "rc.3 上 --upgrade-check 退出码为 0"
assert_stdout_contains "stable dsh-v0.2.0 | rc dsh-v0.2.1-rc.4 | alpha dsh-v0.2.2-alpha.2" "按通道分别展示最新 tag"
assert_stdout_contains "比较通道   : auto（本地 rc，比较 rc/stable）" "auto 跟随本地通道的晋级阶梯"
assert_stdout_contains "上游有更新版本（0.2.1-rc.3 → 0.2.1-rc.4）" "同线 rc.4 被判为可升级"
assert_stdout_contains "升级       : dshctl --install --ref dsh-v0.2.1-rc.4" "升级目标锁在同线 rc.4"
assert_stdout_not_contains "dshctl --install --ref dsh-v0.2.2-alpha.2" "不把下一版本线的 alpha 当作升级目标"
assert_stdout_contains "跨通道参考 : 全通道最新为 dsh-v0.2.2-alpha.2" "跨通道最新仅作参考提示"
assert_equals "$(awk 'END{print NR}' "$FAKE_BIN/lsremote-count")" "1" "通道统计只发起一次 ls-remote"

# 2) --channel alpha：显式跨线到 alpha
run_dshctl --upgrade-check --channel alpha
assert_rc 0 "--channel alpha 退出码为 0"
assert_stdout_contains "alpha（--channel alpha，比较 alpha/rc/stable）" "显式指定 alpha 比较范围"
assert_stdout_contains "升级       : dshctl --install --ref dsh-v0.2.2-alpha.2" "alpha 通道推荐 alpha.2"

# 3) --channel stable：只跟正式版比
run_dshctl --upgrade-check --channel stable
assert_rc 0 "--channel stable 退出码为 0"
assert_stdout_contains "stable（--channel stable）" "显式指定 stable 比较范围"
assert_stdout_contains "本地已是该通道最新（dsh-v0.2.0）" "rc.3 高于 stable 0.2.0，判为已最新"
assert_stdout_not_contains "升级       :" "stable 通道下不给出升级命令"

# 4) --channel any：全通道最新（保留旧行为）
run_dshctl --upgrade-check --channel any
assert_rc 0 "--channel any 退出码为 0"
assert_stdout_contains "any（全通道）" "显式指定全通道"
assert_stdout_contains "升级       : dshctl --install --ref dsh-v0.2.2-alpha.2" "any 下推荐全通道最新"

# 5) stable 用户：新正式版必须能推荐（不能只看同版本线）
emit_tags dsh-v0.2.0 dsh-v0.2.1 dsh-v0.2.2-alpha.2
set_local_version 0.2.0
run_dshctl --upgrade-check
assert_rc 0 "stable 用户 --upgrade-check 退出码为 0"
assert_stdout_contains "auto（本地 stable，比较 stable）" "stable 用户只比较 stable 通道"
assert_stdout_contains "上游有更新版本（0.2.0 → 0.2.1）" "跨版本线的正式版可被推荐"
assert_stdout_contains "升级       : dshctl --install --ref dsh-v0.2.1" "推荐目标是新的正式 tag"

# 6) 上游尚无正式版：--channel stable 给出明确说明而不是误报
emit_tags dsh-v0.2.1-rc.3 dsh-v0.2.1-rc.4
set_local_version 0.2.1-rc.3
run_dshctl --upgrade-check --channel stable
assert_rc 0 "无 stable tag 时退出码为 0"
assert_stdout_contains "stable 无" "无正式版时通道行显示「无」"
assert_stdout_contains "上游暂无该通道 tag" "显式 stable 时说明该通道为空"

# 7) 同通道两位数序号仍按数值定序
emit_tags dsh-v0.2.1-alpha.9 dsh-v0.2.1-alpha.10
set_local_version 0.2.1-alpha.9
run_dshctl --upgrade-check
assert_rc 0 "alpha.9 上 --upgrade-check 退出码为 0"
assert_stdout_contains "alpha dsh-v0.2.1-alpha.10" "通道内取 alpha.10 而非字符串序"
assert_stdout_contains "升级       : dshctl --install --ref dsh-v0.2.1-alpha.10" "推荐 alpha.10"

# 8) 非法用法
run_dshctl --upgrade-check --channel nightly
assert_rc 1 "非法 --channel 取值退出码为 1"
assert_output_contains "--channel 只接受 auto / stable / rc / alpha / any" "非法取值给出允许列表"

run_dshctl --channel rc
assert_rc 1 "--channel 单独使用退出码为 1"
assert_output_contains "选项 --channel 只能与 --upgrade-check 一起使用" "缺少 --upgrade-check 时给出提示"

run_dshctl --upgrade-check --channel
assert_rc 1 "--channel 缺值退出码为 1"
assert_output_contains "选项 --channel 缺少取值" "缺值时给出提示"

finish
