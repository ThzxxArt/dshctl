#!/usr/bin/env bash
# 参数校验：操作互斥、取值合法性、模式-参数匹配

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

run_dshctl --install --status
assert_rc 1 "安装与状态互斥"
assert_output_contains "操作冲突" "互斥错误提示"

run_dshctl --start --stop
assert_rc 1 "服务操作互斥"
assert_output_contains "操作冲突" "服务互斥错误提示"

run_dshctl --install --port abc
assert_rc 1 "非法端口（非数字）"
assert_output_contains "必须是数字" "端口非数字提示"

run_dshctl --install --port 0
assert_rc 1 "端口 0 越界"
assert_output_contains "超出范围" "端口越界提示"

run_dshctl --install --port 70000
assert_rc 1 "端口 70000 越界"

run_dshctl --install --host 0.0.0.0 --no-web-lan
assert_rc 1 "host 0.0.0.0 与 --no-web-lan 冲突"
assert_output_contains "冲突" "监听地址冲突提示"

run_dshctl --plugin-add
assert_rc 1 "--plugin-add 缺少规格"
assert_output_contains "缺少插件规格" "插件规格缺失提示"

run_dshctl --profile desktop --plugin-list
assert_rc 1 "profile 名 desktop 为官方保留"
assert_output_contains "保留" "保留 profile 提示"

run_dshctl --install --trusted-host "bad host"
assert_rc 1 "trusted-host 含空白字符非法"
assert_output_contains "不能包含" "trusted-host 非法提示"

run_dshctl --install --node-major abc
assert_rc 1 "--node-major 非法取值"

run_dshctl --install --log-max-mb nope
assert_rc 1 "--log-max-mb 非法取值"

run_dshctl --install --git-proxy http://127.0.0.1:1 --proxy-scope bogus
assert_rc 1 "非法 --proxy-scope 取值"
assert_output_contains "proxy-scope" "proxy-scope 错误提示"

run_dshctl --install --last 10
assert_rc 1 "--last 不能用于安装模式"

run_dshctl --rollback --ref v1.0.0
assert_rc 1 "--rollback 与 --ref 冲突"
assert_output_contains "不能同时使用" "回退参数冲突提示"

run_dshctl --install -y --api-key
assert_rc 1 "选项缺少取值"
assert_output_contains "缺少取值" "缺值错误提示"

finish
