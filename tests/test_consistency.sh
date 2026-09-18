#!/usr/bin/env bash
# 仓库工程一致性：脚本版本、CHANGELOG、README、语法与可执行位

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

script_version="$(sed -n 's/^DSHCTL_VERSION="\(.*\)"$/\1/p' "$DSHCTL")"
assert_command "能解析 DSHCTL_VERSION" test -n "$script_version"

assert_command "bash -n 语法检查" bash -n "$DSHCTL"
assert_command "脚本具备可执行权限" test -x "$DSHCTL"
assert_equals "$(head -n1 "$DSHCTL")" "#!/usr/bin/env bash" "脚本 shebang 正确"
assert_command "包含 SPDX 许可证标识" grep -qF "SPDX-License-Identifier: MIT" "$DSHCTL"

assert_file_exists "$PROJECT_ROOT/LICENSE" "LICENSE 存在"
assert_file_exists "$PROJECT_ROOT/CHANGELOG.md" "CHANGELOG 存在"
assert_file_exists "$PROJECT_ROOT/README.md" "中文 README 存在"
assert_file_exists "$PROJECT_ROOT/README.en.md" "英文 README 存在"
assert_file_exists "$PROJECT_ROOT/CONTRIBUTING.md" "贡献指南存在"
assert_file_exists "$PROJECT_ROOT/CODE_OF_CONDUCT.md" "行为准则存在"
assert_file_exists "$PROJECT_ROOT/SECURITY.md" "安全政策存在"
assert_file_exists "$PROJECT_ROOT/docs/usage.md" "使用手册存在"
assert_file_exists "$PROJECT_ROOT/docs/troubleshooting.md" "排障手册存在"
assert_file_exists "$PROJECT_ROOT/docs/development.md" "开发指南存在"

assert_command "CHANGELOG 包含当前版本小节" grep -qF "## [$script_version]" "$PROJECT_ROOT/CHANGELOG.md"
assert_command "README 徽章指向仓库地址" grep -qF "github.com/ThzxxArt/dshctl" "$PROJECT_ROOT/README.md"
assert_command "脚本内包含项目主页" grep -qF "github.com/ThzxxArt/dshctl" "$DSHCTL"

# macOS 自带 Bash 3.2 会把紧随 $var 的多字节字节吞进变量名（C locale 下），
# 运行时表现为 "unbound variable" 或值丢失；必须写成 ${var}。这里做静态防线。
mb_hits=""
for mb_file in "$DSHCTL" "$TESTS_DIR/lib.sh"; do
  mb_out="$(awk '
    /^[[:space:]]*cat <<.EOF.$/ { skip = 1; next }
    skip { if ($0 == "EOF") skip = 0; next }
    /^[[:space:]]*#/ { next }
    /[$][A-Za-z_][A-Za-z0-9_]*[^ -~]/ { print FILENAME ":" FNR ": " $0 }
  ' "$mb_file")"
  if [ -n "$mb_out" ]; then
    mb_hits="$mb_hits$mb_out
"
  fi
done
if [ -n "$mb_hits" ]; then
  _fail "存在 \$var 紧跟多字节字符的模式（需写成 \${var} 以兼容 macOS Bash 3.2）："
  printf '%s\n' "$mb_hits" | sed 's/^/    /'
else
  _pass "无 \$var 紧跟多字节字符的模式（macOS Bash 3.2 兼容）"
fi

run_dshctl --version
assert_rc 0 "--version 在隔离环境可用"
assert_stdout_contains "dshctl.sh v$script_version" "--version 与脚本内版本一致"

finish
