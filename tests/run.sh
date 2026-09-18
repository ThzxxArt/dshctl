#!/usr/bin/env bash
# 测试入口：依次运行 tests/test_*.sh，任一文件失败则整体失败。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total=0
failed=0

for t in "$TESTS_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  total=$((total + 1))
  printf '\n===== %s =====\n' "$(basename "$t")"
  if bash "$t"; then
    :
  else
    failed=$((failed + 1))
  fi
done

if [ "$total" -eq 0 ]; then
  echo "未发现测试文件（tests/test_*.sh）" >&2
  exit 1
fi

printf '\n----------------------------------------\n'
if [ "$failed" -eq 0 ]; then
  printf '全部通过：%d 个测试文件\n' "$total"
  exit 0
fi
printf '测试失败：%d/%d 个测试文件未通过\n' "$failed" "$total"
exit 1
