#!/usr/bin/env bash
# 服务日志来源自适应：--url 与 --status 不能假定 web.log 存在。
# systemd 模式下日志落在 journald，pid 模式下落在日志文件；两者都必须能取到地址与端口。

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap teardown EXIT

setup

STATE="$TEST_HOME/.local/state/dsh"
UNIT_DIR="$TEST_HOME/.config/systemd/user"
mkdir -p "$STATE"

# ---------- 场景 1：pid 模式从日志文件取地址 ----------
printf 'dsh web: http://127.0.0.1:3080/?token=PIDTOKENAAA\n' > "$STATE/web.log"
run_dshctl --url
assert_rc 0 "pid 模式 --url 退出码为 0"
assert_stdout_contains "PIDTOKENAAA" "pid 模式从日志文件取到 token"

# 日志为追加写入，应取最后一次启动打印的地址
printf 'dsh web: http://127.0.0.1:3080/?token=PIDTOKENBBB\n' >> "$STATE/web.log"
run_dshctl --url
assert_stdout_contains "PIDTOKENBBB" "日志追加后取最后一次启动的 token"
assert_stdout_not_contains "PIDTOKENAAA" "不再输出上一次启动的 token"

# ---------- 场景 2：无日志时提示先启动 ----------
rm -f "$STATE/web.log"
run_dshctl --url
assert_rc 1 "无日志时 --url 失败"
assert_output_contains "请先 dshctl --start" "无日志时提示先启动"

# ---------- 场景 3：systemd 模式从 journald 取地址（本次修复的主路径） ----------
mkdir -p "$UNIT_DIR"
: > "$UNIT_DIR/dsh.service"
make_stub "$FAKE_BIN/systemctl" '#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "is-active" ] && exit 0; done
exit 0'
make_stub "$FAKE_BIN/journalctl" '#!/usr/bin/env bash
echo "booting dsh web"
echo "dsh web: https://dsh.example.com/?token=SYSTEMDTOKENCCC"'

# 故意留下「上一次 pid 模式」的过期 token，验证 systemd 模式不会误取文件日志
printf 'dsh web: http://127.0.0.1:3080/?token=STALEPIDTOKEN\n' > "$STATE/web.log"

run_dshctl --url
assert_rc 0 "systemd 模式 --url 退出码为 0"
assert_stdout_contains "SYSTEMDTOKENCCC" "systemd 模式从 journald 取到 token"
assert_stdout_not_contains "STALEPIDTOKEN" "systemd 模式不误取遗留的文件日志 token"

# ---------- 场景 4：journald 无地址时报错并指明来源 ----------
make_stub "$FAKE_BIN/journalctl" '#!/usr/bin/env bash
echo "nothing useful here"'
run_dshctl --url
assert_rc 1 "journald 无地址时 --url 失败"
assert_output_contains "journalctl --user -u dsh" "报错指明日志来源为 journald"

# ---------- 场景 5：服务未运行时提示地址可能失效 ----------
make_stub "$FAKE_BIN/journalctl" '#!/usr/bin/env bash
echo "dsh web: https://dsh.example.com/?token=SYSTEMDTOKENCCC"'
make_stub "$FAKE_BIN/systemctl" '#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "is-active" ] && exit 3; done
exit 0'
run_dshctl --url
assert_rc 0 "服务未运行时 --url 仍给出地址"
assert_output_contains "可能已失效" "服务未运行时提示地址可能失效"

# ---------- 场景 6：--status 在 systemd 模式下解析端口 ----------
# 注意：DSH_PORT=0 时 --status 仅在端口真实处于监听时才回显端口号，
# 否则「解析失败」与「解析到但未监听」输出相同，无法区分。故起一个临时监听进程。
make_stub "$FAKE_BIN/systemctl" '#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "is-active" ] && { echo active; exit 0; }; done
exit 0'
rm -f "$STATE/web.log"

STUB_PORT=""
for p in 34567 34568 34569 34570 34571; do
  if ! ss -ltn 2>/dev/null | grep -q ":$p "; then STUB_PORT="$p"; break; fi
done

if [ -z "$STUB_PORT" ] || ! command -v python3 >/dev/null 2>&1; then
  _fail "缺空闲端口或 python3，无法验证 --status 的端口解析"
else
  python3 -m http.server "$STUB_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
  LISTENER=$!
  # 等待端口真正进入监听，不依赖固定 sleep 时长
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ss -ltn 2>/dev/null | grep -q ":$STUB_PORT " && break
    sleep 0.5
  done
  make_stub "$FAKE_BIN/journalctl" "#!/usr/bin/env bash
echo \"dsh web: https://dsh.example.com/?token=SYSTEMDTOKENCCC\"
echo \"listening http://127.0.0.1:${STUB_PORT}\""
  run_dshctl --status --port 0
  assert_rc 0 "systemd 模式 --status 退出码为 0"
  assert_stdout_contains "$STUB_PORT" "--status 从 journald 解析出端口"
  kill "$LISTENER" 2>/dev/null || true
  wait "$LISTENER" 2>/dev/null || true
fi

# ---------- 场景 7：--doctor 在 systemd 模式下经 journald 做插件诊断 ----------
# do_doctor 发现问题时 return 1（本测试环境必有未安装项），故只断言输出内容。
make_stub "$FAKE_BIN/journalctl" '#!/usr/bin/env bash
echo "dsh web: https://dsh.example.com/?token=SYSTEMDTOKENCCC"
echo "failed to load loader entry: @dsh-external/dsh-super-injector"'
run_dshctl --doctor
assert_output_contains "插件加载" "--doctor 经 journald 检出插件加载错误"

# ---------- 回归护栏：这些函数不得再直读日志文件路径 ----------
for fn in do_url do_status do_doctor; do
  body="$(sed -n "/^${fn}()/,/^}/p" "$DSHCTL")"
  if printf '%s' "$body" | grep -q 'WEB_LOG_FILE'; then
    _fail "${fn} 不应再直读 WEB_LOG_FILE（应经 service_log_text）"
  else
    _pass "${fn} 已收敛到 service_log_text"
  fi
done

finish
