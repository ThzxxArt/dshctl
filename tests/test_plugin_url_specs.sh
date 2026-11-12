#!/usr/bin/env bash
# URL 规格（GitHub Release tarball）安装：透传、成功/失败提示与更新提示

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

mkdir -p "$TEST_HOME/deepseek-harness/apps/cli" "$TEST_HOME/deepseek-harness/.git" \
  "$TEST_HOME/.local/bin"
printf '{"name":"@deepseek-ai/dsh","version":"0.2.2-rc.2"}\n' \
  > "$TEST_HOME/deepseek-harness/apps/cli/package.json"

URL_TGZ='https://github.com/owner/repo/releases/download/v1.2.3/pkg-1.2.3.tgz'
URL_ZIP='https://github.com/owner/repo/releases/download/v1.2.3/pkg.zip'
URL_SRC='https://github.com/owner/repo/archive/refs/tags/v1.2.3.tar.gz'
URL_BARE='https://example.com/download/pkg'

# 假启动器：记录参数并按文件内容决定退出码（env -i 不传自定义变量）
write_launcher() { # $1=退出码
  make_stub "$TEST_HOME/.local/bin/dsh" "#!/usr/bin/env bash
printf '%s\n' \"\$*\" >> \"\$HOME/plugin-calls.txt\"
exit $1"
}

# ---------- 帮助文案 ----------
run_dshctl --help
assert_rc 0 "--help 退出码为 0"
assert_stdout_contains "https://.../x.tgz" "帮助列出 URL tarball 规格"
assert_stdout_contains "GitHub Release 的 npm tarball" "帮助说明 URL 来源"

# ---------- dry-run 原样透传 ----------
write_launcher 0
run_dshctl --plugin-add "$URL_TGZ" --dry-run
assert_rc 0 "--plugin-add URL --dry-run 退出码为 0"
assert_stdout_contains "dsh plugin --profile web add $URL_TGZ" "dry-run 原样输出 URL（未被当成本地路径）"

# ---------- 安装成功：锁定提示 + 参数透传 ----------
run_dshctl --plugin-add "$URL_TGZ"
assert_rc 0 "URL 规格安装成功"
assert_output_contains "版本锁定到该地址" "安装成功后提示 URL 依赖已锁定"
assert_output_contains "--plugin-update 不会替换它" "提示 --plugin-update 不会升级 URL 依赖"
assert_command "URL 原样传给 dsh plugin add" grep -qF "add $URL_TGZ" "$TEST_HOME/plugin-calls.txt"

# ---------- 安装失败：按 URL 形态给出提示 ----------
write_launcher 1

run_dshctl --plugin-add "$URL_ZIP"
assert_rc 1 ".zip 规格安装失败"
assert_output_contains "zip 不能直接安装" "zip 失败提示区分资产类型"
assert_output_contains "npm pack 生成的 .tgz" "zip 失败提示正确格式"

run_dshctl --plugin-add "$URL_SRC"
assert_rc 1 "源码归档安装失败"
assert_output_contains "源码归档" "识别 GitHub Source code 归档"
assert_output_contains "package/" "解释源码归档的目录布局差异"

run_dshctl --plugin-add "$URL_BARE"
assert_rc 1 "无扩展名 URL 安装失败"
assert_output_contains "按远程 tarball 处理" "普通 URL 失败提示 tarball 要求"

# ---------- 更新提示：只列出 URL 依赖 ----------
write_launcher 0
PROFILE_DIR="$TEST_HOME/.dsh/profiles/web"
mkdir -p "$PROFILE_DIR"
cat > "$PROFILE_DIR/package.json" <<'JSON'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {
    "dsh-url-plugin": "https://github.com/owner/repo/releases/download/v1.2.3/pkg-1.2.3.tgz",
    "dsh-normal-plugin": "^1.0.0"
  }
}
JSON

run_dshctl --plugin-update
assert_rc 0 "--plugin-update 退出码为 0"
assert_output_contains "dsh-url-plugin" "更新前列出 URL 依赖"
assert_output_contains "pnpm update 不会升级它们" "说明 URL 依赖不会被 pnpm update 升级"
assert_stdout_not_contains "dsh-normal-plugin" "普通版本范围依赖不误报"

finish
