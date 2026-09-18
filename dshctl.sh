#!/usr/bin/env bash
#  SPDX-License-Identifier: MIT
#  项目主页: https://github.com/ThzxxArt/dshctl
# =============================================================================
#  dshctl.sh — DeepSeek Harness (dsh) 安装 · 运维 · 清理 一体化脚本
# -----------------------------------------------------------------------------
#  基于官方仓库源码安装：https://github.com/deepseek-ai/deepseek-harness
#
#  安装流程会依次完成：
#    1. 环境与依赖检查（OS / 架构 / git / curl）
#    2. Node.js 就绪（nvm 优先，官方二进制 tar 包兜底）
#    3. 启用 Corepack 并激活仓库锁定的 pnpm 版本
#    4. 克隆或更新官方源码仓库（支持分支 / tag / commit）
#    5. pnpm install（含 lefthook 钩子自愈）→ 可选 typecheck → pnpm run build
#    6. 写入 .env（DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL）
#    7. 安装 `dsh` 启动器到 ~/.local/bin
#    8. 可选：局域网访问 / systemd --user 常驻服务 / 无头模式自检
#
#  运维能力：--status 状态 / --doctor 体检 / --start|--stop|--restart|--logs 服务控制
#  插件能力：--plugin-list / --plugin-add / --plugin-remove / --plugin-update / --plugin-why
#             （--profile 指定 profile，默认 web；插件变更需重启服务生效）
#  模型维护：--model-show / --model-check / --model-fix（0.1.6 Messages 协议兼容排障）
#  数据维护：--data-backup / --data-restore / --data-archive-sessions / --data-prune
#  版本能力：--rollback / --upgrade-check / --url / --backups-list / --backups-prune
#  卸载能力：--uninstall 部分卸载 / --purge 完全卸载（自动备份运行数据）
#  便捷能力：--register 注册全局命令 dshctl / --unregister 移除
#
#  用法（不带操作参数时显示帮助）:
#    bash dshctl.sh --install -y --api-key sk-xxx
#    bash dshctl.sh --install --shallow --port 4000 --systemd
#    bash dshctl.sh --status / --doctor / --restart / --logs
#    bash dshctl.sh --plugin-list / --plugin-add <规格> / --plugin-remove <名字>
#    bash dshctl.sh --uninstall
#    bash dshctl.sh --purge -y
#    bash dshctl.sh --register        # 注册后可全局使用: dshctl --status
#
#  许可: MIT（详见仓库 LICENSE 文件）；dsh 本体为 MIT 许可。
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# 默认配置
# -----------------------------------------------------------------------------
DSH_REPO_URL="${DSH_REPO_URL:-https://github.com/deepseek-ai/deepseek-harness.git}"
DSH_REF="${DSH_REF:-master}"
DSH_DIR="${DSH_DIR:-$HOME/deepseek-harness}"
DSH_NODE_MAJOR="${DSH_NODE_MAJOR:-24}"
DSH_PNPM_FALLBACK="${DSH_PNPM_FALLBACK:-11.7.0}"
DSH_HOST="${DSH_HOST:-127.0.0.1}"
DSH_PORT="${DSH_PORT:-3080}"
DSH_API_KEY="${DSH_API_KEY:-}"
DSH_BASE_URL="${DSH_BASE_URL:-}"

# 代理（优先级：命令行参数 > 环境变量）
DSH_GIT_PROXY="${DSH_GIT_PROXY:-${GIT_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}}"
DSH_GITHUB_MIRROR="${DSH_GITHUB_MIRROR:-}"
DSH_PROXY_SCOPE="${DSH_PROXY_SCOPE:-global}"   # global | local | system | none
DSH_NO_PROXY="${DSH_NO_PROXY:-}"

# 下载加速镜像（留空 = 自动探测：官方不可达时回退到国内镜像）
DSH_NPM_MIRROR="${DSH_NPM_MIRROR:-}"
DSH_NODE_MIRROR="${DSH_NODE_MIRROR:-}"
DEFAULT_NPM_MIRROR="https://registry.npmmirror.com"
DEFAULT_NODE_MIRROR="https://npmmirror.com/mirrors/node"
NO_MIRROR=0

ASSUME_YES=0
DO_BUILD=1
DO_TYPECHECK=0
DO_INSTALL_DEPS=1
DO_LAUNCHER=1
DO_SYSTEMD=0
DO_HEADLESS_SELFCHECK=0
SHALLOW=0
FORCE_CLEAN=0
DO_UNINSTALL=0
DO_PURGE=0
DO_WEB_LAN=0
WEB_LAN_EXPLICIT=0
SKIP_NODE_INSTALL=0
PROXY_EXPLICIT=0
PROXY_SCOPE_EXPLICIT=0
PROXY_DISABLED=0
DO_STATUS=0
DO_DOCTOR=0
DO_INSTALL=0
DO_REGISTER=0
DO_UNREGISTER=0
HAS_ARGS=0
PORT_EXPLICIT=0
SEEN_OPTS=()
MODE=""
SERVICE_ACTION=""
DRY_RUN=0
DO_BACKUP=1
FORCE_REBUILD=0
PLUGIN_ACTION=""
PLUGIN_PROFILE="web"
PLUGIN_SPECS=()
MODEL_ACTION=""
MODEL_BASE_URL=""

# dshctl 自身版本
DSHCTL_VERSION="1.4.0"
# 新操作组全局状态
DATA_ACTION=""
DATA_ARCHIVE=""
BACKUP_ACTION=""
BACKUP_KEEP=""
DO_URL=0
DO_UPGRADE_CHECK=0
DO_ROLLBACK=0
ROLLBACK_REF=""
DO_VERSION=0
LAST_LINES=""
TRUSTED_HOSTS=()
FORCE_UPDATE=0
UPDATE_FAILED=0

LOG_FILE="${DSH_LOG_FILE:-$HOME/.dshctl.log}"
LOG_MAX_MB="${DSH_LOG_MAX_MB:-5}"
WEB_LAN_PATCH="${DSH_WEB_LAN_PATCH:-$HOME/.local/share/dsh/web-lan.patch.yml}"
STATE_DIR="$HOME/.local/state/dsh"
WEB_PID_FILE="$STATE_DIR/web.pid"
WEB_LOG_FILE="$STATE_DIR/web.log"
STATE_PORT_FILE="$STATE_DIR/port"
LOCK_FILE="$HOME/.dshctl.lock"
LOCK_DIR=""

# dsh 数据目录（与 dsh 的 $DSH_HOME 保持一致，支持 ~ 展开）
DSH_HOME_ABS="${DSH_HOME:-$HOME/.dsh}"
DSH_HOME_ABS="${DSH_HOME_ABS/#\~/$HOME}"
# 展示用路径（主目录缩写为 ~）
DSH_HOME_DISPLAY="${DSH_HOME_ABS/#$HOME/~}"

# 插件 profile 根目录
PROFILES_DIR="$DSH_HOME_ABS/profiles"

# 安装状态记录（用于升级前自动备份与版本兼容检测）
STATE_INSTALL_VERSION_FILE="$STATE_DIR/installed.version"
STATE_INSTALL_HEAD_FILE="$STATE_DIR/installed.head"
STATE_INSTALL_HISTORY_FILE="$STATE_DIR/installed.history"

# 旧版本（dsh-install 时代）文件名，用于兼容迁移与清理
LEGACY_LOG="$HOME/.dsh-install.log"
LEGACY_LOCK="$HOME/.dsh-install.lock"
LEGACY_STAMP_NAME=".dsh-install-stamp"

# -----------------------------------------------------------------------------
# 输出与日志
# -----------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"; C_BLUE="$(tput setaf 4)"; C_DIM="$(tput dim)"
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s[%s]%s %s\n'        "$C_DIM" "$(_ts)" "$C_RESET" "$*"; }
info() { printf '%s[%s]%s %s%s%s\n'    "$C_DIM" "$(_ts)" "$C_RESET" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s[%s]%s %s✔%s %s\n'  "$C_DIM" "$(_ts)" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[%s]%s %s⚠%s %s\n'  "$C_DIM" "$(_ts)" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[%s]%s %s✘%s %s\n'  "$C_DIM" "$(_ts)" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; FAIL_LINE="${BASH_LINENO[0]:-}"; exit 1; }

step() {
  printf '\n%s%s══> %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"
}

# FAIL_LINE: 由 ERR trap / die 记录最后失败位置，供退出时定位
FAIL_LINE=""
QUIET_EXIT=0
_on_err() { FAIL_LINE="${BASH_LINENO[0]:-${LINENO:-?}}"; }
trap '_on_err' ERR

cleanup() {
  local code=$?
  trap - ERR
  if [ "$code" -ne 0 ] && [ "${QUIET_EXIT:-0}" -ne 1 ]; then
    if [ -n "${FAIL_LINE:-}" ]; then
      err "脚本在第 ${FAIL_LINE} 行附近失败（退出码 ${code}）。"
    else
      err "脚本执行失败（退出码 ${code}）。"
    fi
    err "完整日志：$LOG_FILE"
  fi

  # 关闭日志管道写端，等待 tee 排空后再读日志（避免退出竞态丢日志）
  exec 1>&3 2>&4
  if [ -n "${TEE_PID:-}" ]; then
    local i=0
    while kill -0 "$TEE_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if kill -0 "$TEE_PID" 2>/dev/null; then
      kill "$TEE_PID" 2>/dev/null || true
    fi
    wait "$TEE_PID" 2>/dev/null || true
  fi
  if [ -n "${LOG_FIFO_DIR:-}" ]; then
    rm -rf -- "$LOG_FIFO_DIR"
  fi
  if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
    rm -rf -- "$LOCK_DIR" 2>/dev/null || true
  fi

  # 失败时打印日志尾部：仅在输出被重定向（原始 stdout 非终端）且 stderr 仍为终端时
  # 有意义；交互式运行时日志已镜像到屏幕，重复打印只会刷屏。
  if [ "$code" -ne 0 ] && [ "${QUIET_EXIT:-0}" -ne 1 ] && [ -f "$LOG_FILE" ] \
     && [ "${OUT_IS_TTY:-1}" -ne 1 ] && [ -t 2 ]; then
    printf '%s----- 日志末尾 40 行 -----%s\n' "$C_DIM" "$C_RESET" >&2
    tail -n 40 -- "$LOG_FILE" >&2 || true
  fi
  return "$code"
}

# -----------------------------------------------------------------------------
# 日志管道：终端与日志文件同时输出
#   参数解析完成后才安装：保证 --log 生效，且退出时可等待 tee 落盘
# -----------------------------------------------------------------------------
prepare_logging() {
  # 旧版本日志兼容：使用默认日志路径时，把 .dsh-install.log(.1) 迁移为新名
  # （必须放在可写性检查之前，否则新建的空文件会让迁移被跳过）
  local migrated_legacy=0
  if [ "$LOG_FILE" = "$HOME/.dshctl.log" ]; then
    if [ -f "$LEGACY_LOG" ] && { [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; }; then
      if mv -f -- "$LEGACY_LOG" "$LOG_FILE" 2>/dev/null; then
        migrated_legacy=1
      fi
    fi
    if [ -f "${LEGACY_LOG}.1" ] && [ ! -f "${LOG_FILE}.1" ]; then
      mv -f -- "${LEGACY_LOG}.1" "${LOG_FILE}.1" 2>/dev/null || true
    fi
  fi

  local dir
  dir="$(dirname -- "$LOG_FILE")"
  if ! mkdir -p -- "$dir" 2>/dev/null || ! { : >> "$LOG_FILE"; } 2>/dev/null; then
    printf '警告: 无法写入日志文件 %s，回退到 /tmp/dshctl.log\n' "$LOG_FILE" >&2
    LOG_FILE="/tmp/dshctl.log"
    if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
      printf '警告: /tmp 也不可写，本次仅输出到终端，不写日志文件。\n' >&2
      LOG_FILE="/dev/null"
    fi
  fi

  # 日志轮转：超过阈值时归档为 .1（保留一份）
  case "$LOG_MAX_MB" in
    ''|*[!0-9]*) warn "无效的日志阈值: ${LOG_MAX_MB}（按 5 MB 处理）"; LOG_MAX_MB=5 ;;
  esac
  local rotated=0
  if [ -f "$LOG_FILE" ] && [ "$LOG_MAX_MB" -gt 0 ] 2>/dev/null; then
    local size_mb
    size_mb=$(( $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) / 1048576 ))
    if [ "$size_mb" -ge "$LOG_MAX_MB" ]; then
      if mv -f -- "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null; then
        rotated=1
      fi
    fi
  fi

  # 记录原始 stdout 是否为终端：失败收尾据此决定是否兜底打印日志尾部（避免重复刷屏）
  OUT_IS_TTY=0
  if [ -t 1 ]; then OUT_IS_TTY=1; fi

  # 保留原始输出流：tee 通过 fd 3 写回终端
  exec 3>&1 4>&2
  TEE_PID=""
  LOG_FIFO_DIR=""

  local fifo=""
  if command -v mkfifo >/dev/null 2>&1; then
    LOG_FIFO_DIR="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$LOG_FIFO_DIR" ] && mkfifo -- "$LOG_FIFO_DIR/pipe" 2>/dev/null; then
      fifo="$LOG_FIFO_DIR/pipe"
    else
      if [ -n "$LOG_FIFO_DIR" ]; then
        rm -rf -- "$LOG_FIFO_DIR"
      fi
      LOG_FIFO_DIR=""
    fi
  fi

  if [ -n "$fifo" ]; then
    tee -a -- "$LOG_FILE" < "$fifo" >&3 &
    TEE_PID=$!
    exec > "$fifo" 2>&1
  else
    # 无 mkfifo 环境兜底：进程替换，退出阶段无法严格等待 tee
    exec > >(tee -a -- "$LOG_FILE") 2>&1
  fi
  if [ "$rotated" -eq 1 ]; then
    log "旧日志已轮转为 ${LOG_FILE}.1（阈值 ${LOG_MAX_MB} MB）"
  fi
  if [ "$migrated_legacy" -eq 1 ]; then
    log "已迁移旧版日志: $LEGACY_LOG -> $LOG_FILE"
  fi
  return 0
}

banner() {
  cat <<'EOF'
 __        __  _   _
|  \  ___ |  |/ | / |   DeepSeek Harness
|  | / _ \|  |  |/  |   安装 · 运维 · 清理
|__| \___/|__|__/|__|   Model + Harness = Agent
EOF
}

show_version() {
  printf 'dshctl.sh v%s（DeepSeek Harness 安装 · 运维 · 清理）\n' "$DSHCTL_VERSION"
  printf '项目主页: https://github.com/ThzxxArt/dshctl\n'
  printf '脚本路径: %s\n' "$(script_self_path "$0" 2>/dev/null || printf '%s' "$0")"
  local ver=""
  ver="$(installed_dsh_version || true)"
  if [ -n "$ver" ]; then
    printf '已装 dsh: %s\n' "$ver"
  else
    printf '已装 dsh: 未安装\n'
  fi
  return 0
}

# -----------------------------------------------------------------------------
# 参数解析
# -----------------------------------------------------------------------------
usage() {
  cat <<'EOF'
dshctl.sh — DeepSeek Harness (dsh) 安装 · 运维 · 清理 一体化脚本

用法:
  bash dshctl.sh <操作> [选项]      # 不带操作参数时显示本帮助

  校验规则：操作参数互斥（只能选一个）；安装专属参数仅能与 --install 一起使用
  （--dry-run 预览除外）；非法取值（端口 / 枚举 / 缺值等）会直接报错退出。

操作（必须显式指定其一，安装请用 --install）:
      --install             安装 / 更新（克隆源码 + 依赖 + 构建 + 启动器）
      --status              查看安装 / 服务 / 端口 / 局域网状态（只读）
      --doctor              环境与网络体检（只读）
      --start | --stop | --restart | --logs
                            启动 / 停止 / 重启 / 跟踪 Web 服务日志
      --uninstall           部分卸载（保留源码与运行数据，除非配合 --clean）
      --purge               完全卸载（自动备份运行数据后彻底清理）
      --register            把本脚本注册为全局命令 dshctl（软链到 ~/.local/bin）
      --unregister          移除全局命令 dshctl（仅删除本脚本创建的链接）
      --plugin-list         列出 profile 已装插件（bundle / 普通依赖）
      --plugin-add SPEC...  安装插件（支持多个；npm 包名 / github:owner/repo#ref / link:路径）
      --plugin-remove NAME...  卸载插件（支持多个）
      --plugin-update [NAME...]  更新插件（不带名字 = 全部更新）
      --plugin-why NAME     查看插件依赖来源（排障用）
      --plugin-repair       重建 profile 锁文件（clean --lockfile + install），
                            用于修复 pnpm 供应链策略（minimumReleaseAge）拦截
      --plugin-policy       审计 minimumReleaseAge 策略（当前值 / 违规包 / 精确等待时间）
      --plugin-policy-set N 设置 minimumReleaseAge=N 分钟（0 = 关闭；默认 1440）
      --plugin-policy-reset 移除该设置，恢复 pnpm 默认（1440 分钟 / 24 小时）
      --data-backup         备份 ~/.dsh 运行数据（会话/凭据/设置）
      --data-restore FILE   从备份恢复 ~/.dsh（恢复前自动备份现状；先停服务）
      --data-archive-sessions  归档旧会话（解决升级后会话不兼容；数据不删除可恢复）
      --data-prune          清理可安全重建的缓存（图片请求缓存等）
      --rollback [REF]      回退到上一次成功安装的版本（或指定 tag/commit）并重建
      --upgrade-check       检查上游最新版本与本地差异（只读）
      --url                 打印 Web UI 访问地址（含 token；局域网开启时含局域网地址）
      --backups-list        列出 dshctl 产生的全部备份（purge/升级前/.env）
      --backups-prune [N]   每类备份保留最近 N 份（默认 3），删除更早的
      --dry-run             预览安装或卸载将执行的操作，不做任何改动
  -h, --help                显示本帮助
  -V, --version             显示脚本版本与已装 dsh 版本

核心选项:
  -y, --yes                 非交互模式，全部使用默认值
      --dir PATH            安装目录（默认: ~/deepseek-harness）
      --repo URL            仓库地址（默认: 官方 GitHub）
      --ref REF             分支 / tag / commit（默认: master）
      --shallow             浅克隆（--depth 1，节省时间与磁盘）
      --clean               删除已有目录后重新克隆（配合 --uninstall 时删除源码）
      --port PORT           Web UI 端口（默认: 3080）
      --host HOST           监听地址（仅支持 127.0.0.1；局域网访问请用 --web-lan）
      --web-lan             允许局域网访问 Web UI（绑定 0.0.0.0，patch 方式实现；
                            会向同网段暴露可执行命令的界面，仅限可信网络）
      提示：dsh 的「设置 / 模型 / 凭据 / 插件配置」页面为设计上的本机（loopback）
            专属；局域网浏览器访问会报 settings are unavailable，建议在宿主机用
            localhost 访问，或用 SSH 隧道把端口转发到本地后再配置。
      --no-web-lan          保持仅本机访问（默认；交互安装时会询问）
      --api-key KEY         写入 .env 的 DEEPSEEK_API_KEY
      --base-url URL        设置模型 API 地址（写入 settings.yaml 的 llm-deepseek.baseURL；
                            dsh 0.1.6+ 不允许把 DEEPSEEK_BASE_URL 写在 .env）

网络 / 代理 / 加速选项:
      --git-proxy URL       显式指定代理，同时导出 http(s)_proxy 给 git/curl/pnpm 使用
                            （亦可写为 --proxy）；按 --proxy-scope 决定是否写入 git 配置
      --github-mirror URL   GitHub 镜像加速，如 https://gitclone.com/github.com/
      --proxy-scope SCOPE   代理写入 git 配置的范围: global(默认) | local | system | none
                            none 表示仅设置本次运行的环境变量，不改动 git 配置
      --no-proxy            不设置任何代理（忽略环境变量中的 https_proxy）
      --npm-mirror URL      npm/pnpm 注册表镜像（如 https://registry.npmmirror.com）
      --node-mirror URL     Node.js 下载镜像（如 https://npmmirror.com/mirrors/node）
      --no-mirror           禁用镜像自动探测回退（仅用官方源）

  说明：未指定镜像时会自动探测：官方源不可达而国内镜像可达时自动切换（会提示）。
        未指定代理时会自动探测本地常见代理端口（7890/7891/7897/1080 等），
        仅当官方网络不可达时自动启用（--no-proxy 可禁用）。
        若只检测到环境变量中的代理（https_proxy 等）且未显式传 --git-proxy，
        则仅对本次运行生效，不会改动 git 配置；需要持久化时请显式指定。
        --git-proxy 默认只对 https://github.com 生效（通过 git 的按 URL 配置），
        这样不会影响你访问其他代码仓库。撤销方式见 --help 末尾。
        注意：DSH 本体不支持 SOCKS 代理（会跳过并直连），socks5:// 仅对 git/curl 生效；
        Web UI 与模型调用需要代理时，请填写代理软件提供的 HTTP 端口。

构建选项:
      --no-build            只安装依赖，不执行构建
      --typecheck           安装后额外运行 pnpm run typecheck
      --skip-deps           跳过 pnpm install（复用已有依赖）
      --rebuild             强制重跑依赖安装与构建（忽略"源码未变化"智能跳过）
      --force-update        更新源码时丢弃本地修改（git reset --hard 到目标 ref），
                            用于解决"本地改动阻塞快进合并"；未跟踪文件保留

集成选项:
      --launcher            安装 dsh 启动器到 ~/.local/bin（默认开启）
      --no-launcher         不安装启动器
      --systemd             安装并启动 systemd --user 服务（仅 Linux，需要启动器）
      --headless-selfcheck  构建后用无头模式做一次最小自检
      --node-major N        安装的 Node.js 主版本（默认: 24）
      --pnpm-version V      pnpm 版本兜底值（默认: 11.7.0）
      --skip-node-install   若 Node 版本不匹配则报错退出，不自动安装

运维选项:
      --status              显示安装/服务/端口/局域网状态（只读）
      --doctor              环境与网络体检，给出修复建议（只读）
      --start               启动 Web 服务（systemd 或后台进程）
      --stop                停止 Web 服务
      --restart             重启 Web 服务
      --logs                跟踪 Web 服务日志（Ctrl+C 退出；配 --last N 只看最近 N 行）
      --dry-run             只预览将要执行的操作，不做任何改动
      --log FILE            指定日志文件（默认: ~/.dshctl.log）
      --log-max-mb N        日志轮转阈值 MB（默认: 5，0 关闭）

插件管理（需先 --install；bundle 插件变更后需重启服务才生效）:
      --profile NAME        指定 profile（插件操作默认 web；服务控制可用于其他 profile）
      说明：插件安装/卸载/更新完成后会检测服务状态：交互时询问是否重启，
            -y 或非交互环境自动重启；安装插件 = 安装可执行代码，请确认来源可信。

模型维护（dsh 0.1.6+ Base URL 配置规范排障）:
      --model-show          查看生效的模型配置（key 脱敏、来源标注、合规性检查）
      --model-check         连通性自检：headless 发一条最小测试消息
      --model-fix           修复不合规 Base URL：.env 中的设置（任何值，0.1.6+ 会导致
                            拒绝启动）自动注释并备份；settings/环境变量旧根地址给指引
      --model-set-base URL  设置模型 API 地址（写入 settings.yaml 的 llm-deepseek.baseURL，
                            dsh 热读取无需重启；并自动清理 .env 非法项）
      说明：dsh 0.1.6 起默认 Messages 协议（官方端点 https://api.deepseek.com/anthropic）；
            Base URL 只允许来自 settings.yaml 或启动环境变量，写进 .env 会被拒绝启动。

数据维护（运行数据位于 ~/.dsh，升级前后建议先 --data-backup）:
      --data-backup         备份 ~/.dsh 到 ~/dshctl-backup-<时间戳>.tar.gz
      --data-restore FILE   从备份恢复（自动备份现状并先停止服务）
      --data-archive-sessions
                            把 sessions/ 整体归档为 sessions-archive-<时间戳>
                            （升级后旧会话不兼容、发不出消息时的软重置；数据保留）
      --data-prune          清理可重建的图片请求缓存等

版本管理:
      --rollback [REF]      回退到上一次成功安装的版本（或指定 ref/tag/commit），
                            自动重新构建；不回滚 ~/.dsh 数据
      --upgrade-check       对比上游最新 tag / master 与本地版本（只读）

访问助手:
      --url                 打印带 token 的 Web UI 地址（局域网开启时附局域网地址与
                            loopback 配置限制提示）
      --trusted-host HOST   添加允许访问 GUI 的地址/主机名（可重复；随 --install
                            写入启动器，或在 --start 时临时附加）

备份管理:
      --backups-list        列出全部备份（purge / 升级前 / .env 备份）
      --backups-prune [N]   每类保留最近 N 份（默认 3）

维护选项:
      --uninstall           卸载：停止服务、移除启动器（保留源码，除非配合 --clean）
      --purge               完全卸载：删除源码、~/.dsh 运行数据（会话/凭据/设置）、
                            安装日志及写入过的 git 代理配置；需交互确认，-y 跳过
      --no-backup           跳过数据备份（--purge 与「升级前自动备份」均生效）
      --register            注册全局命令 dshctl（软链到 ~/.local/bin/dshctl）
      --unregister          移除全局命令 dshctl（仅当链接指向本脚本时）
  -h, --help                显示本帮助

示例:
  bash dshctl.sh                          # 不带操作参数：显示本帮助
  bash dshctl.sh --install -y --api-key sk-xxxx
  bash dshctl.sh --install --shallow --typecheck --systemd
  bash dshctl.sh --install --dir /opt/dsh --ref v0.1.2-alpha.1 --port 4000
  bash dshctl.sh --install --web-lan --port 4000     # 允许局域网访问
  bash dshctl.sh --install --npm-mirror https://registry.npmmirror.com
  bash dshctl.sh --install --git-proxy http://127.0.0.1:7890 --api-key sk-xxxx
  bash dshctl.sh --install --github-mirror https://gitclone.com/github.com/
  bash dshctl.sh --register               # 注册后可直接 dshctl --status
  bash dshctl.sh --plugin-list            # 查看已装插件
  bash dshctl.sh --plugin-add github:dsh-external/dsh-session-search#main
  bash dshctl.sh --plugin-add @deepseek-ai/dsh-subagent-codex
  bash dshctl.sh --plugin-remove dsh-session-search
  bash dshctl.sh --plugin-update          # 更新全部插件
  bash dshctl.sh --plugin-repair          # 修复 pnpm 供应链策略拦截（重建 profile 锁文件）
  bash dshctl.sh --plugin-policy          # 审计 policy 状态与违规包
  bash dshctl.sh --plugin-policy-set 0    # 关闭 minimumReleaseAge（0 分钟）
  bash dshctl.sh --model-show             # 查看模型配置与协议兼容性
  bash dshctl.sh --model-check            # 模型连通性自检（发一条最小消息）
  bash dshctl.sh --model-fix              # 修复旧官方根地址（0.1.6 协议变更）
  bash dshctl.sh --data-backup            # 备份 ~/.dsh（升级前建议）
  bash dshctl.sh --data-archive-sessions  # 旧会话不兼容时软重置（数据保留）
  bash dshctl.sh --rollback               # 回退到上一次成功安装的版本
  bash dshctl.sh --upgrade-check          # 检查上游最新版本
  bash dshctl.sh --url                    # 打印带 token 的访问地址
  bash dshctl.sh --backups-list           # 查看全部备份
  bash dshctl.sh --status / --doctor / --restart / --logs
  bash dshctl.sh --purge             # 完全卸载（交互确认，自动备份数据）
  bash dshctl.sh --purge -y          # 完全卸载（免确认，脚本用）

撤销 git 代理配置:
  git config --global --unset http.https://github.com/.proxy

项目主页:
  https://github.com/ThzxxArt/dshctl
EOF
}

need_val() {
  [ "$#" -ge 2 ] || die "选项 $1 缺少取值"
  case "$2" in
    --*) die "选项 $1 缺少取值（收到了另一个选项: $2）" ;;
  esac
}

# 参数校验：操作互斥、模式-参数匹配、非法取值
require_mode() {
  local opt="$1"; shift
  local m
  for m in "$@"; do
    [ "$MODE" = "$m" ] && return 0
  done
  if [ -z "$MODE" ]; then
    die "选项 $opt 只能与 --install 一起使用（详见 --help）"
  fi
  die "选项 $opt 不能与 $MODE 操作一起使用；安装/更新请加 --install（详见 --help）"
}

# --profile 专用校验：只能与插件管理或服务控制命令一起使用
require_mode_profile() {
  if [ "$MODE" = "plugins" ] || [ "$MODE" = "service" ]; then return 0; fi
  if [ -z "$MODE" ]; then
    die "选项 --profile 只能与插件管理命令一起使用（--plugin-* 系列，详见 --help）"
  fi
  die "选项 --profile 不能与 $MODE 操作一起使用（仅限插件管理命令与服务控制，详见 --help）"
}

validate_args() {
  # 1) 操作互斥（--dry-run 是修饰符，不算操作）
  local -a modes=()
  local svc_count=0 opt
  local -a plugin_acts=()
  local -a model_acts=()
  local -a data_acts=()
  local -a backup_acts=()
  for opt in ${SEEN_OPTS[@]+"${SEEN_OPTS[@]}"}; do
    case "$opt" in
      --start|--stop|--restart|--logs) svc_count=$((svc_count + 1)) ;;
      --plugin-list)   plugin_acts+=("list") ;;
      --plugin-add)    plugin_acts+=("add") ;;
      --plugin-remove) plugin_acts+=("remove") ;;
      --plugin-update) plugin_acts+=("update") ;;
      --plugin-why)    plugin_acts+=("why") ;;
      --plugin-repair) plugin_acts+=("repair") ;;
      --plugin-policy) plugin_acts+=("policy") ;;
      --plugin-policy-set)   plugin_acts+=("policy-set") ;;
      --plugin-policy-reset) plugin_acts+=("policy-reset") ;;
      --model-show)  model_acts+=("show") ;;
      --model-check) model_acts+=("check") ;;
      --model-fix)   model_acts+=("fix") ;;
      --model-set-base) model_acts+=("set-base") ;;
      --data-backup)   data_acts+=("backup") ;;
      --data-restore)  data_acts+=("restore") ;;
      --data-archive-sessions) data_acts+=("archive-sessions") ;;
      --data-prune)    data_acts+=("prune") ;;
      --backups-list)  backup_acts+=("list") ;;
      --backups-prune) backup_acts+=("prune") ;;
    esac
  done
  [ "$svc_count" -gt 1 ] && die "操作冲突：--start / --stop / --restart / --logs 只能选择一个"
  if [ "${#plugin_acts[@]}" -gt 0 ]; then
    local pa plugin_first="${plugin_acts[0]}" plugin_conflict=0
    for pa in ${plugin_acts[@]+"${plugin_acts[@]}"}; do
      [ "$pa" = "$plugin_first" ] || plugin_conflict=1
    done
    [ "$plugin_conflict" -eq 1 ] && die "操作冲突：插件管理命令只能选择一个（--plugin-* 系列，详见 --help）"
  fi
  if [ "${#model_acts[@]}" -gt 0 ]; then
    local ma model_first="${model_acts[0]}" model_conflict=0
    for ma in ${model_acts[@]+"${model_acts[@]}"}; do
      [ "$ma" = "$model_first" ] || model_conflict=1
    done
    [ "$model_conflict" -eq 1 ] && die "操作冲突：模型维护命令只能选择一个（--model-show / --model-check / --model-fix / --model-set-base）"
  fi
  if [ "${#data_acts[@]}" -gt 0 ]; then
    local da data_first="${data_acts[0]}" data_conflict=0
    for da in ${data_acts[@]+"${data_acts[@]}"}; do
      [ "$da" = "$data_first" ] || data_conflict=1
    done
    [ "$data_conflict" -eq 1 ] && die "操作冲突：数据维护命令只能选择一个（--data-backup / --data-restore / --data-archive-sessions / --data-prune）"
  fi
  if [ "${#backup_acts[@]}" -gt 0 ]; then
    local ba backup_first="${backup_acts[0]}" backup_conflict=0
    for ba in ${backup_acts[@]+"${backup_acts[@]}"}; do
      [ "$ba" = "$backup_first" ] || backup_conflict=1
    done
    [ "$backup_conflict" -eq 1 ] && die "操作冲突：备份管理命令只能选择一个（--backups-list / --backups-prune）"
  fi
  [ "$DO_INSTALL" -eq 1 ] && modes+=("install")
  [ "$DO_STATUS" -eq 1 ] && modes+=("status")
  [ "$DO_DOCTOR" -eq 1 ] && modes+=("doctor")
  [ -n "$SERVICE_ACTION" ] && modes+=("service")
  [ "$DO_UNINSTALL" -eq 1 ] && modes+=("uninstall")
  [ "$DO_REGISTER" -eq 1 ] && modes+=("register")
  [ "$DO_UNREGISTER" -eq 1 ] && modes+=("unregister")
  [ "${#plugin_acts[@]}" -gt 0 ] && modes+=("plugins")
  [ "${#model_acts[@]}" -gt 0 ] && modes+=("model")
  [ "${#data_acts[@]}" -gt 0 ] && modes+=("data")
  [ "${#backup_acts[@]}" -gt 0 ] && modes+=("backups")
  [ "$DO_URL" -eq 1 ] && modes+=("url")
  [ "$DO_UPGRADE_CHECK" -eq 1 ] && modes+=("upgrade-check")
  if [ "${#modes[@]}" -gt 1 ]; then
    die "操作冲突：${modes[*]+"${modes[*]}"} 只能选择一个（详见 --help）"
  fi
  MODE="${modes[0]:-}"
  if [ -z "$MODE" ] && [ "$DRY_RUN" -eq 1 ]; then
    MODE="install"   # 单独的 --dry-run 视为安装预览
  fi

  # 2) 模式-参数匹配（无操作时：只检查安装专属参数，其余交给帮助提示）
  for opt in ${SEEN_OPTS[@]+"${SEEN_OPTS[@]}"}; do
    case "$opt" in
      -y|--yes|--log|--log-max-mb|-h|--help|-V|--version) ;;
      --install|--status|--doctor|--start|--stop|--restart|--logs|--uninstall|--purge|--register|--unregister) ;;
      --plugin-list|--plugin-add|--plugin-remove|--plugin-update|--plugin-why|--plugin-repair|--plugin-policy|--plugin-policy-set|--plugin-policy-reset) ;;
      --model-show|--model-check|--model-fix|--model-set-base) ;;
      --data-backup|--data-restore|--data-archive-sessions|--data-prune) ;;
      --backups-list|--backups-prune) ;;
      --url|--upgrade-check) ;;
      --profile)   require_mode_profile ;;
      --trusted-host) require_mode "$opt" install service ;;
      --last)      require_mode "$opt" service ;;
      --no-proxy)  require_mode "$opt" install doctor ;;
      --no-backup) require_mode "$opt" install uninstall ;;
      --dry-run)   require_mode "$opt" install uninstall plugins model data backups service ;;
      --dir)       require_mode "$opt" install status uninstall upgrade-check ;;
      --port)      require_mode "$opt" install status doctor service ;;
      --clean)     require_mode "$opt" install uninstall ;;
      *)           require_mode "$opt" install ;;
    esac
  done
  if [ -n "$LAST_LINES" ] && [ "$SERVICE_ACTION" != "logs" ]; then
    die "选项 --last 只能与 --logs 一起使用（详见 --help）"
  fi
  if [ "$DO_ROLLBACK" -eq 1 ]; then
    case " ${SEEN_OPTS[*]+"${SEEN_OPTS[*]}"} " in
      *" --ref "*) die "选项 --rollback 与 --ref 不能同时使用（回退目标请在 --rollback 后直接给出）" ;;
    esac
  fi

  # 3) 非法取值校验
  case "$DSH_PORT" in
    ''|*[!0-9]*) die "--port 必须是数字: $DSH_PORT" ;;
  esac
  if [ "$DSH_PORT" -lt 1 ] || [ "$DSH_PORT" -gt 65535 ]; then
    die "--port 超出范围（1-65535）: $DSH_PORT"
  fi
  case "$LOG_MAX_MB" in
    ''|*[!0-9]*) die "--log-max-mb 必须是非负整数: $LOG_MAX_MB" ;;
  esac
  case "$DSH_NODE_MAJOR" in
    ''|*[!0-9]*) die "--node-major 必须是数字: $DSH_NODE_MAJOR" ;;
  esac
  if [ -n "$LAST_LINES" ]; then
    case "$LAST_LINES" in
      ''|*[!0-9]*) die "--last 必须是数字: $LAST_LINES" ;;
    esac
  fi
  if [ -n "$BACKUP_KEEP" ]; then
    case "$BACKUP_KEEP" in
      ''|*[!0-9]*) die "--backups-prune 的保留数量必须是非负整数: $BACKUP_KEEP" ;;
    esac
  fi
  if [ "${#TRUSTED_HOSTS[@]}" -gt 0 ]; then
    local th
    for th in ${TRUSTED_HOSTS[@]+"${TRUSTED_HOSTS[@]}"}; do
      case "$th" in
        '') die "--trusted-host 不能为空" ;;
        *[[:space:]\'\"]*) die "--trusted-host 不能包含空白或引号: $th" ;;
      esac
    done
  fi
  case "$PLUGIN_PROFILE" in
    desktop) die "--profile 名 desktop 为官方保留（Electron 专用），请换一个名字" ;;
    [A-Za-z0-9]*)
      case "$PLUGIN_PROFILE" in
        *[!A-Za-z0-9._-]*) die "--profile 名称含非法字符: $PLUGIN_PROFILE" ;;
      esac
      ;;
    *) die "--profile 名称需以字母或数字开头: $PLUGIN_PROFILE" ;;
  esac
  for opt in ${SEEN_OPTS[@]+"${SEEN_OPTS[@]}"}; do
    if [ "$opt" = "--proxy-scope" ]; then
      case "$DSH_PROXY_SCOPE" in
        global|local|system|none) ;;
        *) die "--proxy-scope 只支持 global | local | system | none（收到: ${DSH_PROXY_SCOPE}）" ;;
      esac
    fi
  done
}

# 原始参数个数：不带任何参数时只显示帮助
HAS_ARGS=$#

# 预扫描 --log / --log-max-mb：先确定日志文件与轮转阈值，保证参数解析阶段的错误也能落盘
_log_scan_prev=""
for _log_scan_arg in "$@"; do
  if [ "$_log_scan_prev" = "--log" ]; then
    LOG_FILE="$_log_scan_arg"
  fi
  if [ "$_log_scan_prev" = "--log-max-mb" ]; then
    LOG_MAX_MB="$_log_scan_arg"
  fi
  _log_scan_prev="$_log_scan_arg"
done

# 安装日志管道与退出清理（--log 指定的文件此时生效，退出时等待 tee 落盘）
prepare_logging
trap cleanup EXIT
trap 'err "收到中断信号，已停止。"; exit 130' INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    -*) SEEN_OPTS+=("$1") ;;
  esac
  case "$1" in
    -y|--yes)            ASSUME_YES=1 ;;
    --dir)               need_val "$@"; DSH_DIR="$2"; shift ;;
    --repo)              need_val "$@"; DSH_REPO_URL="$2"; shift ;;
    --ref)               need_val "$@"; DSH_REF="$2"; shift ;;
    --shallow)           SHALLOW=1 ;;
    --clean)             FORCE_CLEAN=1 ;;
    --port)              need_val "$@"; DSH_PORT="$2"; PORT_EXPLICIT=1; shift ;;
    --host)              need_val "$@"; DSH_HOST="$2"
                         if [ "$DSH_HOST" = "0.0.0.0" ]; then
                           if [ "$WEB_LAN_EXPLICIT" -eq 1 ] && [ "$DO_WEB_LAN" -eq 0 ]; then
                             die "参数冲突：--host 0.0.0.0 与 --no-web-lan 同时指定。"
                           fi
                           DO_WEB_LAN=1; WEB_LAN_EXPLICIT=1
                         fi
                         shift ;;
    --web-lan|--lan)     DO_WEB_LAN=1; WEB_LAN_EXPLICIT=1 ;;
    --no-web-lan|--no-lan) DO_WEB_LAN=0; WEB_LAN_EXPLICIT=1 ;;
    --api-key)           need_val "$@"; DSH_API_KEY="$2"; shift ;;
    --base-url)          need_val "$@"; DSH_BASE_URL="$2"; shift ;;
    --git-proxy|--proxy) need_val "$@"; DSH_GIT_PROXY="$2"; PROXY_EXPLICIT=1; shift ;;
    --github-mirror)     need_val "$@"; DSH_GITHUB_MIRROR="$2"; shift ;;
    --proxy-scope)       need_val "$@"; DSH_PROXY_SCOPE="$2"; PROXY_SCOPE_EXPLICIT=1; shift ;;
    --no-proxy)          DSH_GIT_PROXY=""; DSH_PROXY_SCOPE="none"; PROXY_EXPLICIT=1; PROXY_DISABLED=1 ;;
    --npm-mirror)        need_val "$@"; DSH_NPM_MIRROR="$2"; shift ;;
    --node-mirror)       need_val "$@"; DSH_NODE_MIRROR="$2"; shift ;;
    --no-mirror)         NO_MIRROR=1 ;;
    --no-build)          DO_BUILD=0 ;;
    --typecheck)         DO_TYPECHECK=1 ;;
    --skip-deps)         DO_INSTALL_DEPS=0 ;;
    --rebuild)           FORCE_REBUILD=1 ;;
    --force-update)      FORCE_UPDATE=1 ;;
    --launcher)          DO_LAUNCHER=1 ;;
    --no-launcher)       DO_LAUNCHER=0 ;;
    --systemd)           DO_SYSTEMD=1 ;;
    --headless-selfcheck) DO_HEADLESS_SELFCHECK=1 ;;
    --node-major)        need_val "$@"; DSH_NODE_MAJOR="$2"; shift ;;
    --pnpm-version)      need_val "$@"; DSH_PNPM_FALLBACK="$2"; shift ;;
    --skip-node-install) SKIP_NODE_INSTALL=1 ;;
    --status)            DO_STATUS=1 ;;
    --doctor)            DO_DOCTOR=1 ;;
    --install)           DO_INSTALL=1 ;;
    --register)          DO_REGISTER=1 ;;
    --unregister)        DO_UNREGISTER=1 ;;
    --start)             SERVICE_ACTION="start" ;;
    --stop)              SERVICE_ACTION="stop" ;;
    --restart)           SERVICE_ACTION="restart" ;;
    --logs)              SERVICE_ACTION="logs" ;;
    --plugin-list)       PLUGIN_ACTION="list" ;;
    --plugin-add|--plugin-remove|--plugin-update)
                         case "$1" in
                           --plugin-add)    PLUGIN_ACTION="add" ;;
                           --plugin-remove) PLUGIN_ACTION="remove" ;;
                           --plugin-update) PLUGIN_ACTION="update" ;;
                         esac
                         shift
                         while [ "$#" -gt 0 ]; do
                           case "$1" in
                             -*) break ;;
                           esac
                           PLUGIN_SPECS+=("$1")
                           shift
                         done
                         if [ "$PLUGIN_ACTION" != "update" ] && [ "${#PLUGIN_SPECS[@]}" -eq 0 ]; then
                           die "选项 --plugin-$PLUGIN_ACTION 缺少插件规格"
                         fi
                         continue ;;
    --plugin-why)        need_val "$@"; PLUGIN_ACTION="why"; PLUGIN_SPECS+=("$2"); shift ;;
    --plugin-repair)     PLUGIN_ACTION="repair" ;;
    --plugin-policy)     PLUGIN_ACTION="policy" ;;
    --plugin-policy-set)   need_val "$@"; PLUGIN_ACTION="policy-set"; PLUGIN_SPECS+=("$2"); shift ;;
    --plugin-policy-reset) PLUGIN_ACTION="policy-reset" ;;
    --profile)           need_val "$@"; PLUGIN_PROFILE="$2"; shift ;;
    --model-show)        MODEL_ACTION="show" ;;
    --model-check)       MODEL_ACTION="check" ;;
    --model-fix)         MODEL_ACTION="fix" ;;
    --model-set-base)    need_val "$@"; MODEL_ACTION="set-base"; MODEL_BASE_URL="$2"; shift ;;
    --data-backup)       DATA_ACTION="backup" ;;
    --data-restore)      need_val "$@"; DATA_ACTION="restore"; DATA_ARCHIVE="$2"; shift ;;
    --data-archive-sessions) DATA_ACTION="archive-sessions" ;;
    --data-prune)        DATA_ACTION="prune" ;;
    --backups-list)      BACKUP_ACTION="list" ;;
    --backups-prune)     BACKUP_ACTION="prune"
                         if [ "$#" -ge 2 ]; then
                           case "$2" in
                             -*) ;;
                             *) BACKUP_KEEP="$2"; shift ;;
                           esac
                         fi ;;
    --url)               DO_URL=1 ;;
    --upgrade-check)     DO_UPGRADE_CHECK=1 ;;
    --rollback)          DO_ROLLBACK=1; DO_INSTALL=1
                         if [ "$#" -ge 2 ]; then
                           case "$2" in
                             -*) ;;
                             *) ROLLBACK_REF="$2"; shift ;;
                           esac
                         fi ;;
    --trusted-host)      need_val "$@"; TRUSTED_HOSTS+=("$2"); shift ;;
    --last)              need_val "$@"; LAST_LINES="$2"; shift ;;
    -V|--version)        DO_VERSION=1 ;;
    --dry-run)           DRY_RUN=1 ;;
    --no-backup)         DO_BACKUP=0 ;;
    --uninstall)         DO_UNINSTALL=1 ;;
    --purge)             DO_UNINSTALL=1; DO_PURGE=1 ;;
    --log)               need_val "$@"; LOG_FILE="$2"; shift ;;
    --log-max-mb)        need_val "$@"; LOG_MAX_MB="$2"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "未知选项: $1（使用 --help 查看帮助）" ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# 环境探测
# -----------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
DISTRO="unknown"

detect_distro() {
  if [ "$OS" = "Darwin" ]; then
    DISTRO="macos"
  elif [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
  elif [ -r /etc/redhat-release ]; then
    DISTRO="rhel"
  fi
}

detect_distro

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1（请先安装后重试）"
}

# 危险路径防护：拒绝删除 /、$HOME、空路径、顶层系统目录及 $HOME 的上级目录
reject_dangerous_path() {
  local target="$1" label="${2:-目标}"
  local stripped="${target%/}"
  case "$stripped" in
    ""|"/"|"$HOME"|"."|"..") die "拒绝删除危险路径（${label}）: '$target'" ;;
  esac
  case "$stripped" in
    /*/*) : ;;
    /*)   die "拒绝删除顶层系统目录（${label}）: '$target'" ;;
  esac
  case "$HOME/" in
    "$stripped"/*) die "拒绝删除危险路径（${label}，是用户主目录的上级）: '$target'" ;;
  esac
}

safe_rm_rf() {
  reject_dangerous_path "$1" "${2:-目标}"
  rm -rf -- "$1"
}

# 端口是否被监听（Linux 优先 ss，其次 lsof/netstat）
port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${port} "
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":${port} "
    return $?
  fi
  return 1
}

# 监听指定端口的进程 PID（可能为空；ss → lsof → fuser 逐级兜底）
port_listener_pid() {
  local port="$1" pid=""
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null | grep ":${port} " | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2 || true)"
  fi
  if [ -z "$pid" ] && command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$pid" ] && command -v fuser >/dev/null 2>&1; then
    pid="$(fuser "$port/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -n1 || true)"
  fi
  [ -n "$pid" ] && printf '%s' "$pid"
  return 0
}

# 等待端口真正释放（停止服务时避免进程尚未退出就误报"仍被占用"）
wait_port_free() {
  local port="$1" tries="${2:-10}" i
  for ((i = 1; i <= tries; i++)); do
    port_listening "$port" || return 0
    sleep 1
  done
  ! port_listening "$port"
}

# 未显式指定 --port 时，采用安装时记录的端口（$STATE_DIR/port）
resolve_effective_port() {
  [ "$PORT_EXPLICIT" -eq 1 ] && return 0
  [ -f "$STATE_PORT_FILE" ] || return 0
  local p
  p="$(cat "$STATE_PORT_FILE" 2>/dev/null || true)"
  case "$p" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
    DSH_PORT="$p"
  fi
  return 0
}

# URL 连通性探测：200/3xx/401/403 等有响应即视为可达
check_url() {
  local url="$1" timeout="${2:-8}"
  local code
  code="$(curl -sIL -m "$timeout" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  case "$code" in
    2*|3*|401|403|405) return 0 ;;
    *) return 1 ;;
  esac
}

# 代理 URL 脱敏（隐藏 user:password）
mask_proxy() {
  printf '%s' "$1" | sed -E 's#(://)[^/@]+@#\1***:***@#'
}

# 并发锁：flock 优先，无 flock（如 macOS）时用 mkdir 目录锁兜底
acquire_lock() {
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0
  # 旧版本锁文件兼容：新脚本使用新锁，旧的空锁文件顺手清掉
  if [ -f "$LEGACY_LOCK" ]; then
    rm -f -- "$LEGACY_LOCK" 2>/dev/null || true
    info "已清理旧版锁文件: $LEGACY_LOCK"
  fi
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" || die "无法创建锁文件: $LOCK_FILE"
    flock -n 9 || die "已有另一个 dshctl 实例在运行（锁: ${LOCK_FILE}）。"
    return 0
  fi
  LOCK_DIR="${LOCK_FILE}.d"
  if mkdir -- "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  local old_pid=""
  old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
    rm -rf -- "$LOCK_DIR"
    if mkdir -- "$LOCK_DIR" 2>/dev/null; then
      printf '%s' "$$" > "$LOCK_DIR/pid"
      return 0
    fi
  fi
  die "已有另一个 dshctl 实例在运行（锁目录: ${LOCK_DIR}）。"
}

# -----------------------------------------------------------------------------
# Node.js 就绪
# -----------------------------------------------------------------------------
node_major() { node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1; }
node_minor() { node -v 2>/dev/null | sed 's/^v//' | cut -d. -f2; }
node_ver()   { node -v 2>/dev/null; }

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local major minor
  major="$(node_major)"; minor="$(node_minor)"
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  if [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; then return 0; fi
  if [ "$major" -ge 24 ]; then return 0; fi
  return 1
}

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    set +u
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    set -u
    return 0
  fi
  return 1
}

install_nvm() {
  info "未检测到 nvm，尝试安装 nvm 到 $HOME/.nvm ..."
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash; then
    load_nvm || return 1
    return 0
  fi
  return 1
}

install_node_via_nvm() {
  if ! load_nvm; then
    install_nvm || return 1
  fi
  info "通过 nvm 安装 Node.js v${DSH_NODE_MAJOR} ..."
  set +u
  nvm install "$DSH_NODE_MAJOR" && nvm use "$DSH_NODE_MAJOR" && nvm alias default "$DSH_NODE_MAJOR" >/dev/null 2>&1
  local rc=$?
  set -u
  return $rc
}

install_node_via_tarball() {
  case "$OS-$ARCH" in
    Linux-x86_64)   NODE_PLATFORM="linux-x64" ;;
    Linux-aarch64)  NODE_PLATFORM="linux-arm64" ;;
    Darwin-x86_64)  NODE_PLATFORM="darwin-x64" ;;
    Darwin-arm64)   NODE_PLATFORM="darwin-arm64" ;;
    *) return 1 ;;
  esac
  local base="${NODE_DIST_BASE:-https://nodejs.org/dist}/latest-v${DSH_NODE_MAJOR}.x"
  local file
  file="$(curl -fsSL "$base/" 2>/dev/null | grep -o "node-v[0-9.]*-${NODE_PLATFORM}\.tar\.xz" | head -n1)" || true
  if [ -z "${file:-}" ] && [ "$base" != "https://nodejs.org/dist/latest-v${DSH_NODE_MAJOR}.x" ]; then
    warn "镜像源未找到 Node 包，回退官方源重试..."
    base="https://nodejs.org/dist/latest-v${DSH_NODE_MAJOR}.x"
    file="$(curl -fsSL "$base/" 2>/dev/null | grep -o "node-v[0-9.]*-${NODE_PLATFORM}\.tar\.xz" | head -n1)" || true
  fi
  [ -n "${file:-}" ] || return 1

  local dest="$HOME/.local/node"
  local tmp
  tmp="$(mktemp -d)"
  info "下载 ${file} ..."
  curl -fsSL -o "$tmp/$file" "$base/$file" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$dest"
  tar -xJf "$tmp/$file" -C "$dest" --strip-components=1 || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"

  mkdir -p "$HOME/.local/bin"
  ln -sf "$dest/bin/node" "$HOME/.local/bin/node"
  ln -sf "$dest/bin/npm"  "$HOME/.local/bin/npm"
  ln -sf "$dest/bin/npx"  "$HOME/.local/bin/npx"
  if [ -x "$dest/bin/corepack" ]; then
    ln -sf "$dest/bin/corepack" "$HOME/.local/bin/corepack"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  return 0
}

ensure_node() {
  step "检查 Node.js 运行时"
  if node_ok; then
    ok "Node.js $(node_ver) 已满足要求（^22.19.0 || >=24.0.0）"
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    warn "当前 Node.js $(node_ver) 不符合要求（需要 22.19+ 或 24+）"
  else
    warn "未检测到 Node.js"
  fi

  if [ "$SKIP_NODE_INSTALL" -eq 1 ]; then
    die "已指定 --skip-node-install 且 Node 版本不满足，退出。"
  fi

  if install_node_via_nvm && node_ok; then
    ok "Node.js $(node_ver) 安装完成（nvm）"
    return 0
  fi
  warn "nvm 路径未成功，改用官方二进制包..."

  if install_node_via_tarball && node_ok; then
    ok "Node.js $(node_ver) 安装完成（tarball）"
    return 0
  fi

  warn "官方二进制包路径也失败。请手动安装 Node.js 22.19+ / 24+ 后重试："
  warn "  https://nodejs.org/en/download"
  die "Node.js 环境未就绪。"
}

# -----------------------------------------------------------------------------
# pnpm（Corepack）
# -----------------------------------------------------------------------------
repo_pnpm_version() {
  if [ -f "$DSH_DIR/package.json" ]; then
    local v
    v="$(node -p "try{require('$DSH_DIR/package.json').packageManager||''}catch(e){''}" 2>/dev/null || true)"
    case "$v" in
      pnpm@*) printf '%s' "${v#pnpm@}"; return 0 ;;
    esac
  fi
  printf '%s' "$DSH_PNPM_FALLBACK"
}

ensure_pnpm() {
  step "准备 pnpm（Corepack）"
  local pm_ver="$1"

  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  if ! command -v corepack >/dev/null 2>&1; then
    die "未找到 corepack，Node.js 安装可能不完整。"
  fi

  if ! corepack enable 2>/dev/null; then
    warn "corepack enable 失败（可能需要权限），尝试继续..."
  fi

  if corepack prepare "pnpm@${pm_ver}" --activate 2>/dev/null; then
    ok "pnpm@${pm_ver} 已通过 corepack 激活"
  elif corepack install -g "pnpm@${pm_ver}" 2>/dev/null; then
    ok "pnpm@${pm_ver} 已通过 corepack 全局安装"
  else
    warn "corepack 激活失败，尝试 npm 全局安装 pnpm@${pm_ver}..."
    if command -v npm >/dev/null 2>&1; then
      npm install -g "pnpm@${pm_ver}" || die "pnpm 安装失败。"
      ok "pnpm@${pm_ver} 已通过 npm 安装"
    else
      # 禁用 corepack 严格校验以外的兜底：尝试预装版本
      if corepack pnpm --version >/dev/null 2>&1; then
        ok "使用 corepack 内置 pnpm"
      else
        die "无法准备 pnpm。请手动执行: corepack enable && corepack prepare pnpm@${pm_ver} --activate"
      fi
    fi
  fi

  hash -r 2>/dev/null || true
  local shown
  shown="$(pnpm --version 2>/dev/null || echo '未知')"
  info "当前 pnpm 版本: ${shown}"
}

# -----------------------------------------------------------------------------
# 代理
# -----------------------------------------------------------------------------
# 通过 git 的按 URL 配置只对 github.com 生效，避免影响其它仓库
GIT_PROXY_KEY="http.https://github.com/.proxy"

# 本地常见代理端口（Clash / v2ray / ss 等）
PROXY_CANDIDATE_PORTS="7890 7891 7897 1080 8118 8888"
PROXY_AUTODETECTED=""

export_proxy_env() {
  export http_proxy="$DSH_GIT_PROXY"
  export https_proxy="$DSH_GIT_PROXY"
  export HTTP_PROXY="$DSH_GIT_PROXY"
  export HTTPS_PROXY="$DSH_GIT_PROXY"
  export all_proxy="$DSH_GIT_PROXY"
  export ALL_PROXY="$DSH_GIT_PROXY"
  if [ -n "$DSH_NO_PROXY" ]; then
    export no_proxy="$DSH_NO_PROXY"
    export NO_PROXY="$DSH_NO_PROXY"
  fi
}

# 官方网络不可达时，探测本地常见代理端口（仅 HTTP 代理）
autodetect_proxy() {
  [ "$PROXY_DISABLED" -eq 1 ] && return 0
  [ -n "$DSH_GIT_PROXY" ] && return 0
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0
  check_url "https://github.com" 6 && return 0
  warn "直连 GitHub 不可达，正在探测本地代理端口..."
  local port candidate
  for port in $PROXY_CANDIDATE_PORTS; do
    candidate="http://127.0.0.1:${port}"
    if curl -sIL -m 5 -x "$candidate" -o /dev/null "https://github.com" 2>/dev/null; then
      PROXY_AUTODETECTED="$candidate"
      DSH_GIT_PROXY="$candidate"
      export_proxy_env
      ok "检测到可用本地代理: ${candidate}（仅本次运行生效）"
      break
    fi
  done
  [ -z "$PROXY_AUTODETECTED" ] && warn "未探测到可用本地代理；继续直连（可能下载失败）。"
  return 0
}

apply_proxy() {
  step "配置网络代理"

  # --no-proxy：同时清除继承自 shell 的代理环境变量，确保子进程真正直连
  if [ "$PROXY_DISABLED" -eq 1 ]; then
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    info "已按 --no-proxy 清除代理环境变量（本次运行 git/curl/pnpm 全部直连）。"
    return 0
  fi

  autodetect_proxy

  if [ -z "$DSH_GIT_PROXY" ]; then
    if [ -n "$DSH_GITHUB_MIRROR" ]; then
      info "未设置代理，仅使用 GitHub 镜像加速。"
    else
      info "未设置代理，直连访问。"
    fi
    return 0
  fi

  # 仅来自环境变量/自动探测且未显式指定范围：不改动 git 配置，避免意外持久化
  if [ "$PROXY_EXPLICIT" -eq 0 ] && [ "$PROXY_SCOPE_EXPLICIT" -eq 0 ]; then
    DSH_PROXY_SCOPE="none"
    if [ -z "$PROXY_AUTODETECTED" ]; then
      info "检测到环境变量中的代理: $(mask_proxy "$DSH_GIT_PROXY")（仅本次运行生效，不改动 git 配置）"
      info "如需写入 git 配置，请显式传 --git-proxy URL 与 --proxy-scope global|local。"
    fi
  fi

  case "$DSH_GIT_PROXY" in
    socks5://*|socks5h://*|socks4://*|socks4a://*|socks://*)
      warn "DSH 本体不支持 SOCKS 代理（上游行为：跳过并直连），该代理仅对 git/curl/pnpm 生效。"
      warn "Web UI 与模型调用如需代理，请改用代理软件提供的 HTTP 端口。"
      ;;
  esac

  export_proxy_env
  ok "已为本次运行设置环境变量代理: $(mask_proxy "$DSH_GIT_PROXY")"

  case "$DSH_PROXY_SCOPE" in
    global)
      git config --global "$GIT_PROXY_KEY" "$DSH_GIT_PROXY"
      ok "已写入 git 全局配置（仅对 github.com 生效）"
      ;;
    system)
      if git config --system "$GIT_PROXY_KEY" "$DSH_GIT_PROXY" 2>/dev/null; then
        ok "已写入 git 系统级配置"
      else
        warn "写入 git 系统级配置失败（通常需要 root），已退回环境变量代理。"
      fi
      ;;
    local)
      info "代理将只写入克隆出的仓库本地配置（克隆阶段使用环境变量代理）。"
      if [ -d "$DSH_DIR/.git" ]; then
        git -C "$DSH_DIR" config "$GIT_PROXY_KEY" "$DSH_GIT_PROXY"
        ok "已写入仓库本地配置: $DSH_DIR"
      fi
      ;;
    none)
      info "已指定 --proxy-scope none，不改动任何 git 配置。"
      ;;
    *)
      warn "未知的 --proxy-scope: ${DSH_PROXY_SCOPE}（按 none 处理）"
      DSH_PROXY_SCOPE="none"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# 下载加速镜像
#   显式指定优先；未指定时自动探测：官方不可达而镜像可达则切换
# -----------------------------------------------------------------------------
NODE_DIST_BASE=""

apply_mirrors() {
  [ "$NO_MIRROR" -eq 1 ] && return 0
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0

  # npm / pnpm 注册表
  if [ -z "$DSH_NPM_MIRROR" ]; then
    if ! check_url "https://registry.npmjs.org" 6 && check_url "$DEFAULT_NPM_MIRROR" 6; then
      DSH_NPM_MIRROR="$DEFAULT_NPM_MIRROR"
      info "npm 官方源不可达，自动切换镜像: $DSH_NPM_MIRROR"
    fi
  fi
  if [ -n "$DSH_NPM_MIRROR" ]; then
    export npm_config_registry="$DSH_NPM_MIRROR"
    export NPM_CONFIG_REGISTRY="$DSH_NPM_MIRROR"
    export COREPACK_NPM_REGISTRY="$DSH_NPM_MIRROR"
    info "npm/pnpm 使用镜像: $DSH_NPM_MIRROR"
  fi

  # Node.js 下载源
  if [ -z "$DSH_NODE_MIRROR" ]; then
    if ! check_url "https://nodejs.org/dist/" 6 && check_url "$DEFAULT_NODE_MIRROR/" 6; then
      DSH_NODE_MIRROR="$DEFAULT_NODE_MIRROR"
      info "Node.js 官方源不可达，自动切换镜像: $DSH_NODE_MIRROR"
    fi
  fi
  if [ -n "$DSH_NODE_MIRROR" ]; then
    NODE_DIST_BASE="${DSH_NODE_MIRROR%/}"
    export NVM_NODEJS_ORG_MIRROR="$NODE_DIST_BASE"
    info "Node.js 下载源: $NODE_DIST_BASE"
  fi
}

apply_local_proxy_after_clone() {
  [ "$DSH_PROXY_SCOPE" = "local" ] || return 0
  [ -n "$DSH_GIT_PROXY" ] || return 0
  [ -d "$DSH_DIR/.git" ] || return 0
  git -C "$DSH_DIR" config "$GIT_PROXY_KEY" "$DSH_GIT_PROXY"
  ok "已写入仓库本地代理配置"
}

effective_repo_url() {
  local url="$1"
  if [ -n "$DSH_GITHUB_MIRROR" ]; then
    case "$url" in
      https://github.com/*)
        printf '%s%s' "${DSH_GITHUB_MIRROR%/}/" "${url#https://github.com/}"
        return 0
        ;;
    esac
  fi
  printf '%s' "$url"
}

# -----------------------------------------------------------------------------
# 仓库获取 / 更新
# -----------------------------------------------------------------------------
REPO_HEAD=""

repo_head() { git -C "$DSH_DIR" rev-parse HEAD 2>/dev/null || true; }

# 把忽略项写入 .git/info/exclude（本地专属，不改动被跟踪的 .gitignore，避免阻塞更新）
git_exclude_add() {
  local p="$1" f="$DSH_DIR/.git/info/exclude"
  [ -d "$DSH_DIR/.git" ] || return 0
  mkdir -p "$(dirname -- "$f")" 2>/dev/null || true
  if [ -f "$f" ] && grep -qxF "$p" "$f" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$p" >> "$f" 2>/dev/null || true
  return 0
}

# 自愈：若 .gitignore 的本地改动恰好只是 dshctl 历史上追加的忽略行 → 还原并迁移到 info/exclude
heal_own_gitignore() {
  [ -d "$DSH_DIR/.git" ] || return 0
  if git -C "$DSH_DIR" diff --quiet -- .gitignore 2>/dev/null; then
    return 0
  fi
  local added line
  added="$(git -C "$DSH_DIR" diff -U0 -- .gitignore 2>/dev/null | sed -n 's/^+\([^+].*\)$/\1/p' | sed '/^[[:space:]]*$/d')"
  [ -n "$added" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      ".dshctl-stamp"|".env") ;;
      *) return 0 ;;
    esac
  done <<< "$added"
  if git -C "$DSH_DIR" checkout -- .gitignore 2>/dev/null; then
    git_exclude_add ".dshctl-stamp"
    git_exclude_add ".env"
    info "已自动还原 .gitignore（dshctl 历史追加的忽略项已迁移到 .git/info/exclude）"
  fi
  return 0
}

# 智能跳过：构建产物对应的源码版本未变化时，不再重复 install/build
build_is_current() {
  local stamp="$DSH_DIR/.dshctl-stamp"
  local legacy="$DSH_DIR/$LEGACY_STAMP_NAME"
  [ -n "${REPO_HEAD:-}" ] || return 1
  # 旧版本构建戳兼容：自动迁移为新名
  if [ ! -f "$stamp" ] && [ -f "$legacy" ]; then
    mv -f -- "$legacy" "$stamp" 2>/dev/null || true
  fi
  [ -f "$stamp" ] || return 1
  [ -d "$DSH_DIR/node_modules" ] || return 1
  [ "$(cat "$stamp" 2>/dev/null || true)" = "$REPO_HEAD" ]
}

write_build_stamp() {
  printf '%s' "${REPO_HEAD:-}" > "$DSH_DIR/.dshctl-stamp"
  rm -f -- "$DSH_DIR/$LEGACY_STAMP_NAME" 2>/dev/null || true
  git_exclude_add ".dshctl-stamp"
}

ensure_repo() {
  step "获取 DeepSeek Harness 源码"

  if [ "$FORCE_CLEAN" -eq 1 ] && [ -e "$DSH_DIR" ]; then
    warn "--clean 已指定，删除已有目录: $DSH_DIR"
    safe_rm_rf "$DSH_DIR" "源码目录"
  fi

  if [ -d "$DSH_DIR/.git" ]; then
    if [ "$DO_INSTALL_DEPS" -eq 0 ] && [ "$DO_BUILD" -eq 0 ] && [ "$FORCE_UPDATE" -ne 1 ]; then
      info "检测到已有仓库；--skip-deps --no-build 已指定，跳过远端更新（--force-update 可强制）。"
    else
      info "检测到已有仓库，执行更新..."
      if git -C "$DSH_DIR" fetch --tags --prune origin 2>/dev/null; then
        if [ "$FORCE_UPDATE" -eq 1 ]; then
          if git -C "$DSH_DIR" rev-parse --verify --quiet "origin/$DSH_REF" >/dev/null 2>&1; then
            git -C "$DSH_DIR" checkout -f "$DSH_REF" 2>/dev/null \
              || git -C "$DSH_DIR" checkout -B "$DSH_REF" "origin/$DSH_REF" 2>/dev/null \
              || warn "无法切换到 $DSH_REF"
            git -C "$DSH_DIR" reset --hard "origin/$DSH_REF" 2>/dev/null || true
            info "已强制覆盖本地修改并更新到 origin/$DSH_REF"
          else
            if git -C "$DSH_DIR" checkout -f "$DSH_REF" 2>/dev/null; then
              info "已强制切换（丢弃本地修改）: $DSH_REF"
            else
              warn "无法切换到 ${DSH_REF}，继续使用当前版本。"
            fi
          fi
        else
          heal_own_gitignore
          if ! git -C "$DSH_DIR" checkout "$DSH_REF" 2>/dev/null; then
            if ! git -C "$DSH_DIR" checkout -B "$DSH_REF" "origin/$DSH_REF" 2>/dev/null; then
              warn "无法切换到 ${DSH_REF}，继续使用当前版本。"
            fi
          fi
          if git -C "$DSH_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
            if ! git -C "$DSH_DIR" pull --ff-only; then
              UPDATE_FAILED=1
              warn "快进合并失败：本地有未提交的修改，已跳过更新（源码仍为旧版本）。"
              local dirty=""
              dirty="$(git -C "$DSH_DIR" status --porcelain 2>/dev/null | head -n 5 || true)"
              if [ -n "$dirty" ]; then
                warn "本地改动："
                local dl
                while IFS= read -r dl; do
                  [ -n "$dl" ] && warn "  $dl"
                done <<< "$dirty"
              fi
              warn "强制覆盖本地修改并更新: dshctl --install --force-update（会丢弃上述改动）"
              warn "或重新克隆: dshctl --install --clean"
            fi
          fi
        fi
      else
        warn "拉取远端失败（网络或代理问题），继续使用本地现有版本。"
      fi
    fi
    REPO_HEAD="$(repo_head)"
    ok "源码当前版本: $(git -C "$DSH_DIR" rev-parse --short HEAD)"
    return 0
  fi

  if [ -e "$DSH_DIR" ] && [ -n "$(ls -A "$DSH_DIR" 2>/dev/null)" ]; then
    die "目录已存在且不是 git 仓库: ${DSH_DIR}（可加 --clean 覆盖，或换 --dir）"
  fi

  require_cmd git
  mkdir -p "$(dirname "$DSH_DIR")"

  local repo_url
  repo_url="$(effective_repo_url "$DSH_REPO_URL")"
  [ "$repo_url" != "$DSH_REPO_URL" ] && info "使用镜像地址: $repo_url"

  local clone_args=(--branch "$DSH_REF")
  [ "$SHALLOW" -eq 1 ] && clone_args+=(--depth 1)
  # tag/commit 无法用 --branch，失败后回退为完整克隆 + checkout
  if git clone ${clone_args[@]+"${clone_args[@]}"} "$repo_url" "$DSH_DIR" 2>/dev/null; then
    ok "已克隆（ref=${DSH_REF}）到 $DSH_DIR"
  else
    warn "按 ref 克隆失败，回退为默认克隆 + checkout ..."
    rm -rf "$DSH_DIR"
    local plain=(--depth 1)
    [ "$SHALLOW" -eq 0 ] && plain=()
    git clone ${plain[@]+"${plain[@]}"} "$repo_url" "$DSH_DIR"
    git -C "$DSH_DIR" checkout "$DSH_REF" || die "无法切换到 ref: $DSH_REF"
  fi
  REPO_HEAD="$(repo_head)"
  apply_local_proxy_after_clone
  ok "源码位置: ${DSH_DIR}（HEAD $(git -C "$DSH_DIR" rev-parse --short HEAD)）"
}

# -----------------------------------------------------------------------------
# 依赖安装 / 构建
# -----------------------------------------------------------------------------
install_deps() {
  step "安装项目依赖（pnpm install）"
  if [ "$DO_INSTALL_DEPS" -eq 0 ]; then
    warn "已指定 --skip-deps，跳过依赖安装。"
    return 0
  fi
  if [ "$FORCE_REBUILD" -eq 0 ] && build_is_current; then
    info "源码未变化且依赖已就绪，跳过 pnpm install（--rebuild 可强制重装）。"
    return 0
  fi
  ( cd "$DSH_DIR" && pnpm install )

  # postinstall 会配置 lefthook / merge driver；缓存还原时可能被跳过，这里自愈
  if [ -f "$DSH_DIR/scripts/install-lefthook.mjs" ]; then
    info "校验 Git 钩子集成（lefthook）..."
    if ! ( cd "$DSH_DIR" && node scripts/install-lefthook.mjs ) >/dev/null 2>&1; then
      warn "lefthook 钩子配置未完成（通常不影响运行，仅影响提交期检查）。"
    else
      ok "Git 钩子集成就绪"
    fi
  fi
  ok "依赖安装完成"
}

do_typecheck() {
  [ "$DO_TYPECHECK" -eq 1 ] || return 0
  step "运行类型检查（pnpm run typecheck）"
  ( cd "$DSH_DIR" && pnpm run typecheck )
  ok "类型检查通过"
}

do_build() {
  step "构建项目（pnpm run build）"
  if [ "$DO_BUILD" -eq 0 ]; then
    warn "已指定 --no-build，跳过构建（后续需手动执行 pnpm run build）。"
    return 0
  fi
  if [ "$FORCE_REBUILD" -eq 0 ] && build_is_current; then
    info "源码未变化且已有构建产物，跳过构建（--rebuild 可强制重建）。"
    return 0
  fi
  ( cd "$DSH_DIR" && pnpm run build )
  write_build_stamp
  ok "构建完成"
}

# -----------------------------------------------------------------------------
# 环境变量文件
# -----------------------------------------------------------------------------
write_env() {
  step "配置环境变量（.env）与模型地址（settings.yaml）"
  local env_file="$DSH_DIR/.env"

  # 既有值处理：key 保留；.env 中的 base 为非法（0.1.6+ 拒绝启动）→ 迁移到 settings.yaml 并注释
  local exist_key="" exist_base="" migrated_base=""
  if [ -f "$env_file" ]; then
    exist_key="$(read_env_var "$env_file" DEEPSEEK_API_KEY)"
    exist_base="$(env_baseurl_values "$env_file" | tail -n1 || true)"
  fi
  if [ -z "$DSH_API_KEY" ] && [ -n "$exist_key" ]; then DSH_API_KEY="$exist_key"; fi
  if [ -z "$DSH_BASE_URL" ] && [ -n "$exist_base" ]; then
    DSH_BASE_URL="$exist_base"
    migrated_base="$exist_base"
  fi

  if [ -f "$env_file" ] && [ -n "$exist_base" ]; then
    local ts_mig
    ts_mig="$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$env_file" "$env_file.bak.$ts_mig" 2>/dev/null || true
    if env_comment_baseurl "$env_file"; then
      info "已迁移 .env 中非法的 DEEPSEEK_BASE_URL（dsh 0.1.6+ 的 .env 不允许该变量；原行已注释并备份）"
    else
      warn "无法注释 .env 中的 DEEPSEEK_BASE_URL，请手动处理。"
    fi
  fi

  if [ -z "$DSH_API_KEY" ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    printf '请输入 DeepSeek API Key（可留空，稍后在 Web UI 设置页填写）: '
    read -r DSH_API_KEY || true
  fi

  {
    echo "# 由 dshctl.sh 生成于 $(_ts)"
    echo "# 说明：Web UI 也可在 设置 → 模型 中填写密钥，无需重启服务。"
    if [ -n "$DSH_API_KEY" ]; then
      echo "DEEPSEEK_API_KEY=$DSH_API_KEY"
    else
      echo "# DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxx"
    fi
    echo "# 注意: DEEPSEEK_BASE_URL 不能写在 .env（dsh 0.1.6+ 会拒绝启动）；"
    echo "#       请使用 settings.yaml（llm-deepseek.baseURL，可用 dshctl --model-set-base）或启动环境变量。"
  } > "$env_file"
  chmod 600 "$env_file" 2>/dev/null || true

  if [ -n "$DSH_BASE_URL" ]; then
    local settings_file="$DSH_HOME_ABS/settings.yaml"
    if [ -f "$settings_file" ]; then
      cp -a -- "$settings_file" "$settings_file.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
    if settings_write_baseurl "$DSH_BASE_URL"; then
      ok "已写入 settings.yaml: llm-deepseek.baseURL=$DSH_BASE_URL"
      if [ -n "$migrated_base" ]; then
        info "（旧值已从 .env 迁移至 settings.yaml）"
      fi
    else
      warn "写入 settings.yaml 失败；请手动配置 llm-deepseek.baseURL=$DSH_BASE_URL"
    fi
  fi

  git_exclude_add ".env"
  ok "已写入 ${env_file}（权限 600）"
}

# -----------------------------------------------------------------------------
# 局域网访问（0.0.0.0，patch 方式）
#   上游 CLI 禁用 --host 0.0.0.0，但 webserver 配置层允许；
#   用 --patch 覆盖 webserver 行配置即可，且上游会自动信任本机网卡 IP。
# -----------------------------------------------------------------------------
choose_web_lan() {
  if [ "$WEB_LAN_EXPLICIT" -eq 1 ]; then
    if [ "$DO_WEB_LAN" -eq 1 ]; then
      info "Web UI 将允许局域网访问（绑定 0.0.0.0）"
    else
      info "Web UI 仅本机访问（127.0.0.1）"
    fi
    return 0
  fi

  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    info "Web UI 仅本机访问（默认；如需局域网访问请加 --web-lan）"
    return 0
  fi

  step "Web UI 访问范围"
  printf '是否允许局域网访问（Web UI 绑定 0.0.0.0）？\n'
  printf '安全提醒：这会把可执行命令的 Web UI 暴露给同网段设备，且无登录鉴权，仅限可信网络。\n'
  printf '允许局域网访问？[y/N] '
  local answer=""
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES|Yes) DO_WEB_LAN=1 ;;
    *)               DO_WEB_LAN=0 ;;
  esac
  if [ "$DO_WEB_LAN" -eq 1 ]; then
    warn "已选择允许局域网访问：请确认当前网络可信。"
  else
    info "保持仅本机访问（127.0.0.1）。"
  fi
}

install_web_lan_patch() {
  if [ "$DO_WEB_LAN" -eq 1 ]; then
    step "启用局域网访问（0.0.0.0）"
    mkdir -p "$(dirname -- "$WEB_LAN_PATCH")"
    cat > "$WEB_LAN_PATCH" <<'EOF'
# 由 dshctl.sh 生成：允许局域网访问 Web UI（监听 0.0.0.0）。
# 警告：这会把可执行命令的 Web UI 暴露到局域网，仅限可信网络使用。
# 恢复仅本机访问：删除本文件，并去掉启动参数中的 --patch。
- id: webserver
  config:
    host: '0.0.0.0'
    port: !!js ctx.webStartup.port ?? 3080
    compression: gzip
    compressionLevel: 1
    compressionThresholdBytes: 1024
EOF
    ok "已写入局域网访问补丁: $WEB_LAN_PATCH"
    warn "安全提示：局域网内任何设备都可访问该 Web UI（无登录鉴权），请确认网络可信。"
    warn "提示：dsh 设计上「设置 / 模型 / 凭据 / 插件配置」页面仅在本机（loopback）访问时可用；"
    warn "      通过局域网 IP 访问会提示 settings are unavailable（聊天与插件列表不受影响）。"
    warn "      请在宿主机用 http://localhost:<端口> 访问，或使用 SSH 隧道把远端转发为本地地址。"
    if [ "$DO_LAUNCHER" -ne 1 ]; then
      warn "本次未安装/更新启动器：补丁不会被自动应用，手动启动请加 --patch $WEB_LAN_PATCH"
    fi
  elif [ -f "$WEB_LAN_PATCH" ]; then
    rm -f -- "$WEB_LAN_PATCH"
    rmdir -- "$(dirname -- "$WEB_LAN_PATCH")" 2>/dev/null || true
    ok "已移除旧的局域网访问补丁（恢复仅本机访问）"
  fi
}

# -----------------------------------------------------------------------------
# 启动器
# -----------------------------------------------------------------------------
install_launcher() {
  [ "$DO_LAUNCHER" -eq 1 ] || return 0
  step "安装 dsh 启动器"

  local bin_dir="$HOME/.local/bin"
  local th_flags=""
  if [ "${#TRUSTED_HOSTS[@]}" -gt 0 ]; then
    local t
    for t in ${TRUSTED_HOSTS[@]+"${TRUSTED_HOSTS[@]}"}; do
      th_flags="$th_flags --trusted-host \"$t\""
    done
  fi
  local web_cmd
  if [ "$DO_WEB_LAN" -eq 1 ]; then
    # 0.0.0.0 由 patch 覆盖配置实现；不能再传 --host（上游 CLI 会拒绝 0.0.0.0）
    web_cmd="exec pnpm dsh web --patch \"$WEB_LAN_PATCH\" --port \"\$DSH_PORT\"$th_flags \"\${@:2}\""
  else
    web_cmd="exec pnpm dsh web --host \"\$DSH_HOST\" --port \"\$DSH_PORT\"$th_flags \"\${@:2}\""
  fi
  mkdir -p "$bin_dir"
  cat > "$bin_dir/dsh" <<EOF
#!/usr/bin/env bash
# dsh 启动器（由 dshctl.sh 生成）
set -Eeuo pipefail
DSH_DIR="$DSH_DIR"
DSH_HOST="\${DSH_HOST:-$DSH_HOST}"
DSH_PORT="\${DSH_PORT:-$DSH_PORT}"

[ -d "\$DSH_DIR" ] || { echo "dsh 源码目录不存在: \$DSH_DIR" >&2; exit 1; }
cd "\$DSH_DIR"

# 载入 nvm（若存在），确保能找到 pnpm/node
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
export PATH="\$HOME/.local/bin:\$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

case "\${1:-web}" in
  web)       $web_cmd ;;
  headless)  shift; exec pnpm dsh --profile headless "\$@" ;;
  *)         exec pnpm dsh "\$@" ;;
esac
EOF
  chmod 0755 "$bin_dir/dsh"

  # 记录本次安装端口，供 --start/--stop/--status 等未显式指定 --port 时默认使用
  mkdir -p "$STATE_DIR"
  printf '%s' "$DSH_PORT" > "$STATE_PORT_FILE" 2>/dev/null || true

  if ! (command -v dsh >/dev/null 2>&1); then
    warn "$bin_dir 不在 PATH 中，请把下面一行加入 shell 配置（~/.bashrc 或 ~/.zshrc）："
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
  ok "启动器已安装: $bin_dir/dsh"
}

# -----------------------------------------------------------------------------
# systemd --user 服务
# -----------------------------------------------------------------------------
install_systemd() {
  [ "$DO_SYSTEMD" -eq 1 ] || return 0
  if [ "$OS" != "Linux" ] || ! command -v systemctl >/dev/null 2>&1; then
    warn "当前环境不支持 systemd --user，跳过服务安装。"
    return 0
  fi
  if [ ! -x "$HOME/.local/bin/dsh" ]; then
    warn "未找到启动器 $HOME/.local/bin/dsh，跳过 systemd 服务安装（请勿与 --no-launcher 同用）。"
    return 0
  fi

  step "安装 systemd --user 服务"
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"

  cat > "$unit_dir/dsh.service" <<EOF
[Unit]
Description=DeepSeek Harness (dsh) Web UI
Documentation=https://github.com/deepseek-ai/deepseek-harness
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$DSH_DIR
EnvironmentFile=-$DSH_DIR/.env
Environment=COREPACK_ENABLE_DOWNLOAD_PROMPT=0
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$HOME/.local/bin/dsh web --no-open
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

  # 用户会话总线不可用（如 WSL / 无 DBUS 环境）时优雅降级：保留单元文件但不启动
  if ! systemctl --user daemon-reload 2>/dev/null; then
    warn "systemd --user 不可用（无法连接用户会话总线），已写入单元文件但未启动服务。"
    warn "单元文件: $unit_dir/dsh.service（可在支持 systemd --user 的会话中执行 systemctl --user enable --now dsh 启用）"
    return 0
  fi
  if ! systemctl --user enable --now dsh.service 2>/dev/null; then
    warn "systemctl --user enable --now 未成功，单元文件已保留: $unit_dir/dsh.service"
    return 0
  fi
  ok "服务已启动: systemctl --user status dsh"
  log "查看日志: journalctl --user -u dsh -f"
  if command -v loginctl >/dev/null 2>&1; then
    info "提示：如需在未登录时保持运行，可执行 sudo loginctl enable-linger ${USER:-$(id -un 2>/dev/null)}"
  fi
}

# -----------------------------------------------------------------------------
# 自检 / 卸载
# -----------------------------------------------------------------------------
headless_selfcheck() {
  [ "$DO_HEADLESS_SELFCHECK" -eq 1 ] || return 0
  step "无头模式自检"

  # 与上游凭据解析顺序对齐：环境变量 → .env → ~/.dsh/.credentials.yaml
  local have_key=0
  if [ -n "$DSH_API_KEY" ] || [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    have_key=1
  elif [ -f "$DSH_DIR/.env" ] && grep -qE '^[[:space:]]*DEEPSEEK_API_KEY=[^[:space:]#]' "$DSH_DIR/.env" 2>/dev/null; then
    have_key=1
  elif [ -f "${DSH_HOME:-$HOME/.dsh}/.credentials.yaml" ]; then
    have_key=1
  fi

  if [ "$have_key" -eq 0 ]; then
    warn "未提供 API Key，跳过无头自检（需要真实密钥才能调用模型）。"
    return 0
  fi

  if ( cd "$DSH_DIR" && pnpm dsh --profile headless "回复 OK 即可" ); then
    ok "无头模式自检通过"
  else
    warn "无头模式自检未通过，请检查密钥与网络。"
  fi
}

do_uninstall() {
  step "卸载 DeepSeek Harness 安装产物"
  resolve_effective_port

  local dsh_home="${DSH_HOME:-$HOME/.dsh}"
  dsh_home="${dsh_home/#\~/$HOME}"

  # --purge：先列清单、再确认；所有删除动作都在确认之后
  local backup_file=""
  if [ "$DO_PURGE" -eq 1 ]; then
    reject_dangerous_path "$DSH_DIR" "源码目录"
    reject_dangerous_path "$dsh_home" "DSH_HOME 运行数据"

    local proxy_val=""
    proxy_val="$(git config --global "$GIT_PROXY_KEY" 2>/dev/null || true)"

    local -a purge_items=()
    local -a purge_logs=()
    local default_log="$HOME/.dshctl.log"
    if [ "$LOG_FILE" != "/dev/null" ]; then
      purge_logs+=("$LOG_FILE")
    fi
    if [ "$default_log" != "$LOG_FILE" ]; then
      purge_logs+=("$default_log")
    fi
    # 旧版本日志（兼容清理）
    if [ "$LEGACY_LOG" != "$LOG_FILE" ] && [ "$LEGACY_LOG" != "$default_log" ]; then
      purge_logs+=("$LEGACY_LOG")
    fi
    [ -e "$DSH_DIR" ] && purge_items+=("源码目录     : $DSH_DIR")
    [ -e "$dsh_home" ] && purge_items+=("运行数据     : ${dsh_home}（profiles / storages / 凭据 / 设置）")
    local lf
    for lf in ${purge_logs[@]+"${purge_logs[@]}"}; do
      [ -f "$lf" ] && purge_items+=("安装日志     : $lf")
      [ -f "${lf}.1" ] && purge_items+=("日志归档     : ${lf}.1")
    done
    [ -f "$WEB_LAN_PATCH" ] && purge_items+=("局域网补丁   : $WEB_LAN_PATCH")
    [ -f "$HOME/.config/systemd/user/dsh.service" ] && purge_items+=("systemd 服务 : $HOME/.config/systemd/user/dsh.service")
    [ -d "$STATE_DIR" ] && purge_items+=("服务状态     : ${STATE_DIR}（web.pid / web.log）")
    if [ -L "$HOME/.local/bin/dshctl" ] && [ "$(script_self_path "$HOME/.local/bin/dshctl")" = "$(script_self_path "$0")" ]; then
      purge_items+=("全局命令     : $HOME/.local/bin/dshctl（软链）")
    fi
    [ -n "$proxy_val" ] && purge_items+=("git 代理配置 : $GIT_PROXY_KEY = $proxy_val")
    [ -f "$LEGACY_LOCK" ] && purge_items+=("旧版锁文件   : $LEGACY_LOCK")
    if [ -e "$dsh_home" ] && [ "$DO_BACKUP" -eq 1 ]; then
      backup_file="$HOME/dshctl-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
      purge_items+=("数据备份     : ${backup_file}（删除前自动打包）")
    fi

    if [ "${#purge_items[@]}" -eq 0 ]; then
      info "未发现需要清理的残留。"
    else
      info "以下内容将被处理："
      local item
      for item in ${purge_items[@]+"${purge_items[@]}"}; do
        printf '   - %s\n' "$item"
      done
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 以上为预览，未做任何改动。"
      return 0
    fi

    if [ "${#purge_items[@]}" -gt 0 ] && [ "$ASSUME_YES" -ne 1 ]; then
      if [ -t 0 ]; then
        local answer=""
        printf '确认完全卸载？输入 yes 继续: '
        read -r answer || true
        [ "$answer" = "yes" ] || die "已取消完全卸载。"
      else
        die "非交互环境执行 --purge 需要 -y 确认。"
      fi
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将停止服务并移除启动器（源码保留，未配合 --clean）。"
    return 0
  fi

  # 停止服务：systemd 单元 + 后台进程模式（pid 文件）
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now dsh.service >/dev/null 2>&1 || true
  fi
  if [ -f "$WEB_PID_FILE" ]; then
    service_ctl_pid stop || true
  fi
  rm -f "$HOME/.config/systemd/user/dsh.service"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$HOME/.local/bin/dsh"

  if [ -f "$WEB_LAN_PATCH" ]; then
    rm -f -- "$WEB_LAN_PATCH"
    rmdir -- "$(dirname -- "$WEB_LAN_PATCH")" 2>/dev/null || true
    ok "已移除局域网访问补丁: $WEB_LAN_PATCH"
  fi

  if [ "$DO_PURGE" -eq 1 ]; then
    # 全局命令软链（仅当指向本脚本）
    local self_link="$HOME/.local/bin/dshctl"
    if [ -L "$self_link" ]; then
      if [ "$(script_self_path "$self_link")" = "$(script_self_path "$0")" ]; then
        rm -f -- "$self_link"
        ok "已移除全局命令: $self_link"
      else
        warn "全局命令链接指向其他文件，未移除: $self_link"
      fi
    fi
    # 服务状态目录（web.pid / web.log）
    if [ -d "$STATE_DIR" ]; then
      safe_rm_rf "$STATE_DIR" "服务状态目录"
      ok "已删除服务状态目录: $STATE_DIR"
    fi
    rmdir -- "$(dirname -- "$WEB_LAN_PATCH")" 2>/dev/null || true
    if [ -e "$DSH_DIR" ]; then
      safe_rm_rf "$DSH_DIR" "源码目录"
      ok "已删除源码目录: $DSH_DIR"
    fi
    if [ -e "$dsh_home" ]; then
      if [ "$DO_BACKUP" -eq 1 ]; then
        info "备份运行数据到: $backup_file"
        if tar -czf "$backup_file" -C "$(dirname -- "$dsh_home")" "$(basename -- "$dsh_home")" 2>/dev/null; then
          chmod 600 "$backup_file" 2>/dev/null || true
          ok "备份完成: $backup_file"
        else
          die "备份失败，已中止完全卸载（如确认不需要备份请加 --no-backup 重试）。"
        fi
      fi
      safe_rm_rf "$dsh_home" "DSH_HOME 运行数据"
      ok "已删除运行数据: $dsh_home"
    fi
    if git config --global "$GIT_PROXY_KEY" >/dev/null 2>&1; then
      git config --global --unset "$GIT_PROXY_KEY" 2>/dev/null || true
      ok "已移除 git 全局代理配置"
    fi
    if git config --system "$GIT_PROXY_KEY" >/dev/null 2>&1; then
      git config --system --unset "$GIT_PROXY_KEY" 2>/dev/null \
        || warn "无法移除 git 系统级代理配置（通常需要 root），请手动处理。"
    fi
    local lf2
    for lf2 in ${purge_logs[@]+"${purge_logs[@]}"}; do
      rm -f -- "$lf2" "${lf2}.1" 2>/dev/null || true
    done
    # 安装锁文件：flock 随进程退出自动释放，这里清掉文件本身（含旧版锁）
    rm -f -- "$LOCK_FILE" "$LEGACY_LOCK" 2>/dev/null || true
    ok "完全卸载完成"
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
      info "数据备份保留在: ${backup_file}（确认不需要可手动删除）"
    fi
    if [ -d "$HOME/.nvm" ] || [ -d "$HOME/.local/node" ]; then
      info "共享运行时未删除（如需清理请手动执行）："
      [ -d "$HOME/.nvm" ] && info "  nvm : rm -rf \"$HOME/.nvm\""
      [ -d "$HOME/.local/node" ] && info "  Node: rm -rf \"$HOME/.local/node\" \"$HOME/.local/bin/node\" \"$HOME/.local/bin/npm\" \"$HOME/.local/bin/npx\""
    fi
    return 0
  fi

  if [ "$FORCE_CLEAN" -eq 1 ]; then
    safe_rm_rf "$DSH_DIR" "源码目录"
    ok "已删除源码目录: $DSH_DIR"
  else
    ok "已移除服务与启动器；源码目录保留（完全清理请用 --purge，或加 --clean 仅删源码）: $DSH_DIR"
  fi
  ok "卸载完成"
}

# -----------------------------------------------------------------------------
# 运维：状态 / 体检 / 服务控制 / dry-run
# -----------------------------------------------------------------------------
service_profile() { printf '%s' "${PLUGIN_PROFILE:-web}"; }

service_pid_file() {
  if [ "$(service_profile)" = "web" ]; then
    printf '%s' "$WEB_PID_FILE"
  else
    printf '%s/%s.pid' "$STATE_DIR" "$(service_profile)"
  fi
}

service_log_file() {
  if [ "$(service_profile)" = "web" ]; then
    printf '%s' "$WEB_LOG_FILE"
  else
    printf '%s/%s.log' "$STATE_DIR" "$(service_profile)"
  fi
}

service_mode() {
  if [ "$(service_profile)" = "web" ] && command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/dsh.service" ]; then
    printf 'systemd'
  elif [ -f "$(service_pid_file)" ]; then
    printf 'pid'
  else
    printf 'none'
  fi
}

pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

web_running_pid() {
  local pid=""
  pid="$(cat "$(service_pid_file)" 2>/dev/null || true)"
  if pid_alive "$pid"; then printf '%s' "$pid"; fi
}

do_status() {
  step "DeepSeek Harness 状态"
  printf '  dshctl     : v%s\n' "$DSHCTL_VERSION"
  resolve_effective_port

  if [ -d "$DSH_DIR/.git" ]; then
    REPO_HEAD="$(repo_head)"
    local head branch
    head="$(git -C "$DSH_DIR" rev-parse --short HEAD 2>/dev/null || echo 未知)"
    branch="$(git -C "$DSH_DIR" branch --show-current 2>/dev/null || true)"
    [ -z "$branch" ] && branch="(detached)"
    printf '  源码目录   : %s\n' "$DSH_DIR"
    printf '  源码版本   : %s (%s)\n' "$head" "$branch"
    if build_is_current; then
      printf '  构建状态   : 已构建（与源码一致）\n'
    elif [ -d "$DSH_DIR/node_modules" ]; then
      printf '  构建状态   : 需要 pnpm install / build\n'
    else
      printf '  构建状态   : 未安装依赖\n'
    fi
  else
    printf '  源码目录   : 未安装（%s）\n' "$DSH_DIR"
  fi

  printf '  Node.js    : %s\n' "$(node -v 2>/dev/null || echo 未安装)"
  printf '  pnpm       : %s\n' "$(pnpm --version 2>/dev/null || echo 未安装)"

  if [ -x "$HOME/.local/bin/dsh" ]; then
    printf '  启动器     : %s\n' "$HOME/.local/bin/dsh"
  else
    printf '  启动器     : 未安装\n'
  fi

  local mode
  mode="$(service_mode)"
  case "$mode" in
    systemd)
      local st
      st="$(systemctl --user is-active dsh.service 2>/dev/null || true)"
      printf '  服务模式   : systemd --user（%s）\n' "${st:-未知}"
      ;;
    pid)
      local pid
      pid="$(web_running_pid)"
      if [ -n "$pid" ]; then
        printf '  服务模式   : 后台进程（PID %s）\n' "$pid"
      else
        printf '  服务模式   : 后台进程（PID 文件陈旧）\n'
      fi
      ;;
    *)
      printf '  服务模式   : 未安装服务\n'
      ;;
  esac

  if port_listening "$DSH_PORT"; then
    local lpid lnote
    lpid="$(port_listener_pid "$DSH_PORT")"
    if [ -n "$lpid" ]; then
      lnote="（PID ${lpid}）"
    else
      lnote="（占用进程无法识别，可能来自其他 WSL 发行版/主机）"
    fi
    printf '  端口 %-6s: 监听中%s\n' "$DSH_PORT" "$lnote"
  else
    printf '  端口 %-6s: 未监听\n' "$DSH_PORT"
  fi

  local plugin_pkg="$PROFILES_DIR/web/package.json"
  if [ -f "$plugin_pkg" ]; then
    local pcounts
    pcounts="$(node -e 'const j=require(process.argv[1]);const d=Object.keys(j.dependencies||{});const b=((j.dsh&&j.dsh.profile&&j.dsh.profile.bundles)||[]).filter((x)=>d.includes(x));console.log(d.length+" "+b.length)' "$plugin_pkg" 2>/dev/null || true)"
    if [ -n "$pcounts" ]; then
      printf '  插件 (web) : %s 个依赖（%s 个 bundle）\n' "${pcounts%% *}" "${pcounts##* }"
    fi
  else
    printf '  插件 (web) : 未初始化（%s）\n' "$PROFILES_DIR/web"
  fi

  local model_ver=""
  model_ver="$(installed_dsh_version || true)"
  if [ -n "$model_ver" ]; then
    if [ -n "$(model_old_root_findings)" ] && version_has_messages_protocol "$model_ver"; then
      printf '  模型兼容   : ⚠ 检测到不合规 Base URL 配置（--model-fix 可修复）\n'
    else
      printf '  模型兼容   : ✔ 无问题（dsh %s）\n' "$model_ver"
    fi
  else
    printf '  模型兼容   : 未知（源码未安装）\n'
  fi

  if [ -f "$WEB_LAN_PATCH" ]; then
    if [ -x "$HOME/.local/bin/dsh" ] && grep -q -- '--patch' "$HOME/.local/bin/dsh" 2>/dev/null; then
      printf '  局域网访问 : 已启用（0.0.0.0，启动器已配置补丁）\n'
    else
      printf '  局域网访问 : 补丁存在，但启动器未引用（重跑安装或手动 --patch）\n'
    fi
  else
    printf '  局域网访问 : 未启用（仅本机）\n'
  fi

  local dsh_home="${DSH_HOME:-$HOME/.dsh}"
  if [ -d "$dsh_home" ]; then
    printf '  运行数据   : %s（%s）\n' "$dsh_home" "$(du -sh "$dsh_home" 2>/dev/null | cut -f1)"
  else
    printf '  运行数据   : 无（%s）\n' "$dsh_home"
  fi
  if [ -f "$LOG_FILE" ]; then
    printf '  日志文件   : %s（%s）\n' "$LOG_FILE" "$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)"
  else
    printf '  日志文件   : %s（不存在）\n' "$LOG_FILE"
  fi
}

do_doctor() {
  step "环境体检"
  resolve_effective_port
  local problems=0
  if [ "$PROXY_DISABLED" -eq 1 ]; then
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  fi
  printf '  系统       : %s/%s（%s）\n' "$OS" "$ARCH" "$DISTRO"

  local c
  for c in bash git curl tar; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '  %-10s : ✔ %s\n' "$c" "$(command -v "$c")"
    else
      printf '  %-10s : ✘ 缺少（必需）\n' "$c"
      problems=$((problems + 1))
    fi
  done
  for c in xz flock ss lsof; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '  %-10s : ✔\n' "$c"
    else
      printf '  %-10s : ⚠ 未安装（可选）\n' "$c"
    fi
  done

  if command -v git >/dev/null 2>&1; then
    local gv
    gv="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
    if [ -n "$gv" ]; then
      local gmaj gmin
      gmaj="${gv%%.*}"; gmin="${gv##*.}"
      if [ "$gmaj" -lt 2 ] || { [ "$gmaj" -eq 2 ] && [ "$gmin" -lt 26 ]; }; then
        printf '  git 版本   : ⚠ %s（建议 2.26+）\n' "$gv"
      else
        printf '  git 版本   : ✔ %s\n' "$gv"
      fi
    fi
  fi

  if node_ok; then
    printf '  Node.js    : ✔ %s（满足要求）\n' "$(node_ver)"
  elif command -v node >/dev/null 2>&1; then
    printf '  Node.js    : ⚠ %s（不符，将自动安装 v%s）\n' "$(node_ver)" "$DSH_NODE_MAJOR"
  else
    printf '  Node.js    : ⚠ 未安装（将自动安装 v%s）\n' "$DSH_NODE_MAJOR"
  fi
  printf '  corepack   : %s\n' "$(command -v corepack >/dev/null 2>&1 && echo '✔ 可用' || echo '⚠ 不可用（将退回 npm 安装 pnpm）')"

  # 磁盘 / 内存
  local avail_kb
  avail_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || true)"
  if [ -n "$avail_kb" ]; then
    local avail_gb=$((avail_kb / 1048576))
    if [ "$avail_kb" -lt 5242880 ]; then
      printf '  磁盘空间   : ⚠ %s GB 可用（建议 ≥5 GB）\n' "$avail_gb"
      problems=$((problems + 1))
    else
      printf '  磁盘空间   : ✔ %s GB 可用\n' "$avail_gb"
    fi
  fi
  local mem_mb=""
  if [ -r /proc/meminfo ]; then
    mem_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
  elif [ "$OS" = "Darwin" ] && command -v sysctl >/dev/null 2>&1; then
    mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
  fi
  if [ -n "$mem_mb" ] && [ "$mem_mb" -gt 0 ]; then
    if [ "$mem_mb" -lt 3500 ]; then
      printf '  内存       : ⚠ %s MB（构建建议 ≥4 GB 或加 swap）\n' "$mem_mb"
    else
      printf '  内存       : ✔ %s MB\n' "$mem_mb"
    fi
  fi

  if port_listening "$DSH_PORT"; then
    local dp dnote
    dp="$(port_listener_pid "$DSH_PORT")"
    if [ -n "$dp" ]; then
      dnote="（PID ${dp}）"
    else
      dnote="（占用进程无法识别，可能来自其他 WSL 发行版/主机）"
    fi
    printf '  端口 %-6s: ⚠ 已被占用%s\n' "$DSH_PORT" "$dnote"
  else
    printf '  端口 %-6s: ✔ 空闲\n' "$DSH_PORT"
  fi

  # Web UI 可达性 / 数据占用 / 局域网提示 / 插件加载错误
  if port_listening "$DSH_PORT"; then
    local uicode
    uicode="$(curl -s -m 6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DSH_PORT/" 2>/dev/null || true)"
    case "$uicode" in
      2*|3*|401|403) printf '  Web UI     : ✔ 可达（HTTP %s）\n' "$uicode" ;;
      *[0-9]*)       printf '  Web UI     : ⚠ 响应异常（HTTP %s）\n' "$uicode" ;;
      *)             printf '  Web UI     : ⚠ 无响应（端口已监听但 HTTP 未响应）\n' ;;
    esac
  fi
  if [ -d "$DSH_HOME_ABS" ]; then
    printf '  数据占用   : %s（%s）\n' "$(du -sh "$DSH_HOME_ABS" 2>/dev/null | cut -f1)" "$DSH_HOME_ABS"
    local img_cache_dir="$DSH_HOME_ABS/cache/attachments/request-images"
    if [ -d "$img_cache_dir" ]; then
      printf '  图片缓存   : %s（可 dshctl --data-prune 清理）\n' "$(du -sh "$img_cache_dir" 2>/dev/null | cut -f1)"
    fi
  fi
  if [ -f "$WEB_LAN_PATCH" ]; then
    printf '  局域网提示 : 设置/模型等页面仅 loopback 可用（上游设计）；建议本机 localhost 访问\n'
  fi
  if [ -f "$WEB_LOG_FILE" ]; then
    local plerr=""
    plerr="$(grep -nE "plugin tree failed|failed to (load|apply) loader entry" "$WEB_LOG_FILE" 2>/dev/null | tail -n1 || true)"
    if [ -n "$plerr" ]; then
      printf '  插件加载   : ⚠ 检测到加载错误（dshctl --logs --last 100 查看）\n'
    fi
  fi

  # 网络
  printf '  网络探测   :\n'
  local url name
  local net_fail=0
  for url in "https://github.com|github.com" "https://raw.githubusercontent.com|raw.githubusercontent.com" "https://registry.npmjs.org|registry.npmjs.org" "https://nodejs.org/dist/|nodejs.org"; do
    name="${url#*|}"
    url="${url%%|*}"
    if check_url "$url" 8; then
      printf '    ✔ %s\n' "$name"
    else
      printf '    ✘ %s 不可达\n' "$name"
      net_fail=$((net_fail + 1))
    fi
  done
  if [ "$net_fail" -gt 0 ]; then
    problems=$((problems + net_fail))
    if check_url "$DEFAULT_NPM_MIRROR" 6 && check_url "$DEFAULT_NODE_MIRROR/" 6; then
      printf '    提示: 国内镜像可达，安装时将自动切换（或显式 --npm-mirror / --node-mirror）\n'
    fi
    printf '    提示: 可尝试 --git-proxy 指定代理，或 --github-mirror 加速\n'
  fi

  if [ -n "$DSH_GIT_PROXY" ]; then
    printf '  代理       : %s\n' "$(mask_proxy "$DSH_GIT_PROXY")"
  elif [ "$PROXY_EXPLICIT" -eq 1 ]; then
    printf '  代理       : 未启用（--no-proxy）\n'
  else
    local p found_proxy=""
    for p in $PROXY_CANDIDATE_PORTS; do
      if curl -sIL -m 4 -x "http://127.0.0.1:${p}" -o /dev/null "https://github.com" 2>/dev/null; then
        found_proxy="$p"
        break
      fi
    done
    if [ -n "$found_proxy" ]; then
      printf '  代理       : ⚠ 检测到可用本地代理 127.0.0.1:%s（安装时不可达会自动启用）\n' "$found_proxy"
    else
      printf '  代理       : 未配置\n'
    fi
  fi

  if [ "$problems" -eq 0 ]; then
    ok "体检通过，未发现阻塞问题。"
    return 0
  fi
  QUIET_EXIT=1
  warn "发现 $problems 个问题，请参考上方提示处理后重试。"
  return 1
}

service_ctl_pid() {
  local action="$1"
  local sp pid_file log_file is_web=0
  sp="$(service_profile)"
  pid_file="$(service_pid_file)"
  log_file="$(service_log_file)"
  if [ "$sp" = "web" ]; then is_web=1; fi
  case "$action" in
    start)
      local pid
      pid="$(web_running_pid)"
      if [ -n "$pid" ]; then
        info "服务已在运行（PID ${pid}），无需重复启动。"
        return 0
      fi
      local pre_pid=""
      if [ "$is_web" -eq 1 ]; then
        pre_pid="$(port_listener_pid "$DSH_PORT")"
        if port_listening "$DSH_PORT"; then
          if [ -n "$pre_pid" ]; then
            warn "端口 $DSH_PORT 已被占用（PID ${pre_pid}），本次启动可能失败（可改用 --port 指定其他端口）。"
          else
            warn "端口 $DSH_PORT 已被占用且无法识别占用进程（可能来自其他 WSL 发行版/主机，镜像网络模式下可见）。"
            warn "建议改用其他端口: dshctl --start --port <端口>"
          fi
        fi
      fi
      mkdir -p "$STATE_DIR"
      # 关闭继承自脚本的保存输出 fd（3/4）与锁 fd（9），避免守护进程占住管道
      if [ "$is_web" -eq 1 ]; then
        local -a th_args=()
        if [ "${#TRUSTED_HOSTS[@]}" -gt 0 ]; then
          local t
          for t in ${TRUSTED_HOSTS[@]+"${TRUSTED_HOSTS[@]}"}; do th_args+=(--trusted-host "$t"); done
        fi
        nohup env DSH_PORT="$DSH_PORT" "$HOME/.local/bin/dsh" web --no-open ${th_args[@]+"${th_args[@]}"} >>"$log_file" 2>&1 < /dev/null 3>&- 4>&- 9>&- &
      else
        nohup "$HOME/.local/bin/dsh" --profile "$sp" >>"$log_file" 2>&1 < /dev/null 3>&- 4>&- 9>&- &
      fi
      local new_pid=$!
      printf '%s' "$new_pid" > "$pid_file"
      local i up=0 cur=""
      if [ "$is_web" -eq 1 ]; then
        for ((i = 1; i <= 30; i++)); do
          sleep 1
          # 监听进程与启动前不同，才视为本次启动成功（避免把其他环境的监听误判为自己的）
          cur="$(port_listener_pid "$DSH_PORT")"
          if [ -n "$cur" ] && [ "$cur" != "$pre_pid" ]; then
            up=1
            break
          fi
          pid_alive "$new_pid" || break
        done
      else
        sleep 2
        if pid_alive "$new_pid"; then up=1; fi
      fi
      if [ "$up" -eq 1 ]; then
        if [ "$is_web" -eq 1 ]; then
          ok "已在后台启动（PID ${new_pid}），端口 $DSH_PORT 监听中。"
        else
          ok "已在后台启动 profile「${sp}」（PID ${new_pid}，无端口监控）。"
        fi
        info "日志: tail -f $log_file"
      else
        # 启动失败：清理可能仍存活的子进程，避免留下无 pid 文件的孤儿进程
        if pid_alive "$new_pid"; then
          kill -TERM "$new_pid" 2>/dev/null || true
          for _ in 1 2 3; do
            sleep 1
            pid_alive "$new_pid" || break
          done
          if pid_alive "$new_pid"; then
            kill -KILL "$new_pid" 2>/dev/null || true
          fi
        fi
        rm -f -- "$pid_file"
        warn "启动未成功，最近日志："
        tail -n 20 "$log_file" 2>/dev/null || true
        die "后台启动失败。"
      fi
      ;;
    stop)
      local pid
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      if pid_alive "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        local i
        for ((i = 1; i <= 10; i++)); do
          sleep 1
          pid_alive "$pid" || break
        done
        if pid_alive "$pid"; then
          kill -KILL "$pid" 2>/dev/null || true
          sleep 1
        fi
      fi
      if [ "$is_web" -eq 1 ]; then
        # 端口兜底：launcher 的子进程（node）可能仍持有端口，杀掉后等待真正释放
        if port_listening "$DSH_PORT"; then
          local lpid
          lpid="$(port_listener_pid "$DSH_PORT")"
          if [ -n "$lpid" ]; then
            kill -TERM "$lpid" 2>/dev/null || true
            if ! wait_port_free "$DSH_PORT" 10; then
              kill -KILL "$lpid" 2>/dev/null || true
              wait_port_free "$DSH_PORT" 3 || true
            fi
          fi
        fi
        rm -f -- "$pid_file"
        if port_listening "$DSH_PORT"; then
          local lpid2
          lpid2="$(port_listener_pid "$DSH_PORT")"
          if [ -n "$lpid2" ]; then
            warn "端口 $DSH_PORT 仍被占用（PID ${lpid2}），请手动检查: kill -9 $lpid2"
          else
            warn "端口 $DSH_PORT 仍被占用但无法识别占用进程：可能来自其他 WSL 发行版 / Windows 主机（镜像网络模式下可见）。"
            warn "请检查其他环境，或为本环境改用其他端口: --port <端口>"
          fi
        else
          ok "服务已停止。"
        fi
      else
        rm -f -- "$pid_file"
        ok "服务已停止（profile: ${sp}）。"
      fi
      ;;
  esac
}

require_cmd_launcher() {
  [ -x "$HOME/.local/bin/dsh" ] || die "未找到启动器 $HOME/.local/bin/dsh，请先运行 --install。"
}

# 解析脚本自身真实路径（可移植，跟随软链）
script_self_path() {
  local src="$1"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname -- "$src")" && pwd)"
    src="$(readlink -- "$src")"
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  printf '%s/%s' "$(cd -P "$(dirname -- "$src")" && pwd)" "$(basename -- "$src")"
}

do_register() {
  step "注册全局命令 dshctl"
  local script_path bin_dir link
  script_path="$(script_self_path "$0")"
  bin_dir="$HOME/.local/bin"
  link="$bin_dir/dshctl"
  mkdir -p "$bin_dir"

  if [ -L "$link" ]; then
    local target
    target="$(script_self_path "$link")"
    if [ "$target" = "$script_path" ]; then
      ok "已注册（$link -> ${script_path}）"
    elif [ -e "$link" ]; then
      die "目标已存在且指向其他文件，未改动: $link -> ${target}（请手动处理后重试）"
    else
      rm -f -- "$link"
      ln -s -- "$script_path" "$link"
      ok "原链接已失效，已重新注册: $link -> $script_path"
    fi
  elif [ -e "$link" ]; then
    die "目标已存在同名文件（非本脚本链接），未改动: $link"
  else
    ln -s -- "$script_path" "$link"
    ok "已注册全局命令: dshctl -> $script_path"
  fi

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) warn "$bin_dir 不在 PATH 中，请把下面一行加入 shell 配置（~/.bashrc 或 ~/.zshrc）："
       warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
  info "注册后可直接使用: dshctl --status / dshctl --install -y / dshctl --purge"
  info "提示：脚本移动或重命名后，请重新执行 --register 更新链接。"
}

do_unregister() {
  step "移除全局命令 dshctl"
  local script_path link="$HOME/.local/bin/dshctl"
  script_path="$(script_self_path "$0")"

  if [ -L "$link" ]; then
    local target
    target="$(script_self_path "$link")"
    if [ "$target" = "$script_path" ]; then
      rm -f -- "$link"
      ok "已移除全局命令: $link"
    else
      warn "该链接指向其他文件，未移除: $link -> $target"
    fi
  elif [ -e "$link" ]; then
    warn "存在同名文件（非本脚本链接），未移除: $link"
  else
    info "未注册（$link 不存在），无需处理。"
  fi
}

do_service_action() {
  local action="$SERVICE_ACTION"
  resolve_effective_port
  local mode
  mode="$(service_mode)"

  if [ "$action" = "logs" ]; then
    local lfile n
    lfile="$(service_log_file)"
    n="${LAST_LINES:-}"
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ -n "$n" ]; then
        info "[dry-run] 将显示最近 $n 行服务日志（模式: ${mode}）。"
      else
        info "[dry-run] 将跟踪服务日志（模式: ${mode}）。"
      fi
      return 0
    fi
    if [ "$mode" = "systemd" ]; then
      if [ -n "$n" ]; then
        exec journalctl --user -u dsh -n "$n" --no-pager
      fi
      exec journalctl --user -u dsh -f
    elif [ -f "$lfile" ]; then
      if [ -n "$n" ]; then
        exec tail -n "$n" -- "$lfile"
      fi
      exec tail -n 50 -f -- "$lfile"
    else
      die "没有可跟踪的日志（未安装 systemd 服务，也无后台日志）。"
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 服务操作: ${action}（模式: ${mode}）"
    return 0
  fi

  if [ "$mode" = "systemd" ]; then
    local action_cn=""
    case "$action" in
      start)   action_cn="启动" ;;
      stop)    action_cn="停止" ;;
      restart) action_cn="重启" ;;
    esac
    case "$action" in
      start)   systemctl --user start dsh.service   || die "systemctl --user start 失败（用户总线不可用？）" ;;
      stop)    systemctl --user stop dsh.service    || die "systemctl --user stop 失败" ;;
      restart) systemctl --user restart dsh.service || die "systemctl --user restart 失败" ;;
    esac
    ok "服务已${action_cn}（systemd --user），当前状态: $(systemctl --user is-active dsh.service 2>/dev/null || echo 未知)"
    return 0
  fi

  require_cmd_launcher
  case "$action" in
    start)   service_ctl_pid start ;;
    stop)    service_ctl_pid stop ;;
    restart) service_ctl_pid stop; service_ctl_pid start ;;
  esac
}

# -----------------------------------------------------------------------------
# 插件管理（dsh plugin --profile <name> <pnpm 参数>）
#   profile 目录: $DSH_HOME/profiles/<name>（默认 ~/.dsh/profiles/web）
#   本地路径规格先转绝对路径：启动器会先 cd 进源码目录，避免解析错位
# -----------------------------------------------------------------------------
resolve_plugin_spec() {
  local spec="$1" prefix="" path="" out=""
  case "$spec" in
    "~")   spec="$HOME" ;;
    "~"/*) spec="$HOME/${spec#\~/}" ;;
  esac
  case "$spec" in
    file:*) prefix="file:"; path="${spec#file:}" ;;
    link:*) prefix="link:"; path="${spec#link:}" ;;
    /*)     path="$spec" ;;
    .|./*|..|../*) path="$spec" ;;
    *)      printf '%s' "$spec"; return 0 ;;
  esac
  case "$path" in
    "~")   path="$HOME" ;;
    "~"/*) path="$HOME/${path#\~/}" ;;
  esac
  case "$path" in
    /*) ;;
    *)  path="$PWD/$path" ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    out="$(realpath -m -- "$path" 2>/dev/null || true)"
    [ -n "$out" ] && path="$out"
  fi
  printf '%s%s' "$prefix" "$path"
}

plugin_run() {
  local profile="$1"; shift
  "$HOME/.local/bin/dsh" plugin --profile "$profile" "$@"
}

# ISO8601 UTC 时间戳 → epoch（GNU date 优先，BSD date 兜底；失败返回非零）
timestamp_to_epoch() {
  local ts="$1"
  date -u -d "$ts" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null && return 0
  return 1
}

# 秒数 → 人类可读等待时长
format_wait() {
  local s="$1"
  if [ "$s" -le 0 ]; then
    printf '不足 1 分钟'
  elif [ "$s" -lt 60 ]; then
    printf '%d 秒' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%d 分' $((s / 60))
  else
    printf '%d 小时 %d 分' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

# 解析 pnpm 策略校验输出中的违规行（「还需等待」= 发布时间 - cutoff 时间，精确无需当前时钟）
print_policy_violations() {
  local file="$1" viol
  viol="$(sed -nE 's/^[[:space:]]+(.*) was published at ([0-9T:.Z+-]+), within the minimumReleaseAge cutoff \(([0-9T:.Z+-]+)\).*$/\1|\2|\3/p' "$file" 2>/dev/null \
    | awk -F'|' '{ if (!($1 in seen)) { order[++n] = $1 } seen[$1] = $0 } END { for (i = 1; i <= n; i++) print seen[order[i]] }')"
  [ -n "$viol" ] || return 1
  local pkg pub cut pe ce
  while IFS='|' read -r pkg pub cut; do
    [ -n "$pkg" ] || continue
    pe="$(timestamp_to_epoch "$pub" || true)"
    ce="$(timestamp_to_epoch "$cut" || true)"
    if [ -n "$pe" ] && [ -n "$ce" ] && [ "$pe" -ge "$ce" ]; then
      printf '  · %s：还需等待 %s（发布于 %s）\n' "$pkg" "$(format_wait $((pe - ce)))" "$pub"
    else
      printf '  · %s：发布于 %s（策略截止 %s）\n' "$pkg" "$pub" "$cut"
    fi
  done <<< "$viol"
  return 0
}

# 卸载前预检：目标必须是 profile 依赖中的完整包名（避免 pnpm 报 missing deps 才后知后觉）
plugin_precheck_remove() {
  local pkg="$PROFILES_DIR/$PLUGIN_PROFILE/package.json"
  if [ ! -f "$pkg" ]; then
    die "profile 未初始化: $PROFILES_DIR/${PLUGIN_PROFILE}（没有可卸载的插件）"
  fi
  command -v node >/dev/null 2>&1 || return 0
  local out="" rc=0
  out="$(node -e '
    const fs = require("fs");
    let j;
    try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(2); }
    const deps = Object.keys(j.dependencies || {});
    const wants = process.argv.slice(2);
    const missing = wants.filter((w) => !deps.includes(w));
    if (missing.length === 0) process.exit(0);
    for (const m of missing) {
      const guesses = deps.filter((d) => d.endsWith("/" + m));
      console.log("  " + m + (guesses.length ? " → 是否指: " + guesses.join(" / ") : "（未安装）"));
    }
    console.log("  已装插件: " + (deps.length ? deps.join(", ") : "（无）"));
    process.exit(3);
  ' "$pkg" "$@" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 3 ]; then
    warn "以下卸载目标不在 profile 依赖中（已提前阻止，未调用 pnpm）："
    printf '%s\n' "$out" >&2
    die "请使用完整包名重试（参考上方已装插件列表）。"
  fi
  if [ "$rc" -eq 2 ]; then
    warn "无法解析 profile 清单（${pkg}），跳过卸载预检。"
  fi
  return 0
}

# 配置修改确认（交互询问；非交互需要 -y）
confirm_config_change() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1"
    local ans=""
    read -r ans || true
    case "$ans" in
      y|Y|yes|YES|Yes) return 0 ;;
    esac
    return 1
  fi
  die "非交互环境修改配置需要 -y 确认。"
}

# 读取 profile 当前 minimumReleaseAge（空/undefined/非数字 → 输出空）
plugin_current_policy() {
  local profile="$1" val=""
  val="$(plugin_run "$profile" config get minimumReleaseAge 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  case "$val" in
    ''|undefined|*[!0-9]*) printf '' ;;
    *) printf '%s' "$val" ;;
  esac
}

do_plugin_policy() {
  local profile="$PLUGIN_PROFILE"
  step "minimumReleaseAge 策略审计（profile: ${profile}）"

  local configured=""
  configured="$(plugin_current_policy "$profile")"
  if [ -n "$configured" ]; then
    printf '  当前设置   : %s 分钟（约 %s 小时）\n' "$configured" "$((configured / 60))"
  else
    printf '  当前设置   : 未显式设置（pnpm 11 默认 1440 分钟 / 24 小时）\n'
  fi

  local lock="$PROFILES_DIR/$profile/pnpm-lock.yaml"
  if [ ! -f "$lock" ]; then
    info "profile 尚无锁文件（$lock 不存在），无需审计。"
    return 0
  fi

  local out_file
  out_file="$(mktemp 2>/dev/null || echo "/tmp/dshctl-policy-$$.log")"
  local rc=0
  info "校验锁文件（只读，不修改任何文件）..."
  plugin_run "$profile" install --frozen-lockfile --lockfile-only >"$out_file" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "锁文件通过策略校验，没有「发布未满最小年龄」的依赖。"
    rm -f -- "$out_file"
    return 0
  fi
  if print_policy_violations "$out_file"; then
    printf '\n'
    info "处理方式: 等待上述时间 / --plugin-repair 重建锁文件 / --plugin-policy-set 0 关闭策略"
  else
    warn "校验失败（非最小发布年龄问题），最近输出："
    tail -n 12 -- "$out_file" 2>/dev/null | sed 's/^/    /'
  fi
  rm -f -- "$out_file"
  return 0
}

do_plugin_policy_set() {
  local profile="$PLUGIN_PROFILE" val="${PLUGIN_SPECS[0]:-}"
  case "$val" in
    ''|*[!0-9]*) die "--plugin-policy-set 需要非负整数分钟数（0 = 关闭；1440 = pnpm 默认 24 小时）" ;;
  esac
  local old=""
  old="$(plugin_current_policy "$profile")"
  [ -n "$old" ] || old="未显式设置（默认 1440）"
  if ! confirm_config_change "确认把 profile「${profile}」的 minimumReleaseAge 从 $old 改为 $val 分钟？"; then
    die "已取消（未修改配置）。"
  fi
  plugin_run "$profile" config set minimumReleaseAge "$val" --location project || die "写入配置失败。"
  ok "已设置 minimumReleaseAge=$val 分钟（profile: ${profile}）"
  if [ "$val" -eq 0 ]; then
    warn "已关闭发布年龄保护：新发布的依赖不再有冷静期，请确认来源可信。"
  fi
  info "配置文件: $PROFILES_DIR/$profile/pnpm-workspace.yaml（恢复默认用 --plugin-policy-reset）"
}

do_plugin_policy_reset() {
  local profile="$PLUGIN_PROFILE"
  local old=""
  old="$(plugin_current_policy "$profile")"
  if [ -z "$old" ]; then
    info "当前未显式设置 minimumReleaseAge，无需恢复。"
    return 0
  fi
  if ! confirm_config_change "确认移除 profile「${profile}」的 minimumReleaseAge 设置（恢复默认 1440 分钟）？"; then
    die "已取消（未修改配置）。"
  fi
  local rc=0
  plugin_run "$profile" config delete minimumReleaseAge --location project || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "pnpm config delete 失败，改为显式恢复默认值 1440 分钟。"
    plugin_run "$profile" config set minimumReleaseAge 1440 --location project || die "恢复默认失败。"
  fi
  ok "已恢复 pnpm 默认（1440 分钟 / 24 小时）"
}

# 失败后按已知错误特征给出可操作建议（扫描日志尾部）
plugin_failure_hint() {
  case "${LOG_FILE:-}" in ""|"/dev/null") return 0 ;; esac
  [ -f "$LOG_FILE" ] || return 0
  local recent=""
  recent="$(tail -n 160 -- "$LOG_FILE" 2>/dev/null || true)"
  case "$recent" in
    *ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION*)
      warn "原因：pnpm 11 供应链策略 minimumReleaseAge 拦截——profile 锁文件包含「发布未满最小年龄」的依赖。"
      local hint_file="" viol_out=""
      hint_file="$(mktemp 2>/dev/null || echo "/tmp/dshctl-hint-$$.log")"
      printf '%s\n' "$recent" > "$hint_file" 2>/dev/null || true
      viol_out="$(print_policy_violations "$hint_file" || true)"
      rm -f -- "$hint_file"
      if [ -n "$viol_out" ]; then
        warn "预计自动通过时间："
        local vl
        while IFS= read -r vl; do
          [ -n "$vl" ] && warn "$vl"
        done <<< "$viol_out"
      fi
      if [ "$PLUGIN_ACTION" = "repair" ]; then
        warn "重建后仍被拦截：新解析结果仍含过新的包。请稍后重试，或在以下文件调整 minimumReleaseAge（0 = 关闭）:"
        warn "  $PROFILES_DIR/$PLUGIN_PROFILE/pnpm-workspace.yaml"
      else
        warn "处理（任选其一）:"
        warn "  1) 稍后重试：等这些包超过最小发布年龄后自动通过；"
        warn "  2) 一键重建 profile 锁文件: dshctl --plugin-repair --profile $PLUGIN_PROFILE"
        warn "  3) 信任这些包时，可在以下文件调整 minimumReleaseAge（0 = 关闭）:"
        warn "     $PROFILES_DIR/$PLUGIN_PROFILE/pnpm-workspace.yaml"
      fi
      ;;
    *ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS*)
      warn "原因：要卸载的包名不在 profile 依赖中（需使用完整包名，可用 --plugin-list 查看）。"
      ;;
    *allowBuilds*|*"Ignored build scripts"*|*approve-builds*)
      warn "若上方输出提示 pnpm 的 allowBuilds 拦截（含构建步骤的 git 插件），"
      warn "请把提示的 key 加入以下文件后重试: $PROFILES_DIR/$PLUGIN_PROFILE/pnpm-workspace.yaml"
      ;;
  esac
  return 0
}

do_plugin_list() {
  local dir="$PROFILES_DIR/$PLUGIN_PROFILE"
  step "插件列表（profile: ${PLUGIN_PROFILE}）"
  if [ ! -f "$dir/package.json" ]; then
    info "profile 未初始化: $dir"
    info "首次安装插件可直接执行: dshctl --plugin-add <规格>（会自动初始化 profile）"
    return 0
  fi
  printf '  目录: %s\n' "$dir"
  node -e '
    const j = require(process.argv[1]);
    const deps = j.dependencies || {};
    const bundles = new Set((j.dsh && j.dsh.profile && j.dsh.profile.bundles) || []);
    const names = Object.keys(deps).sort();
    if (names.length === 0) {
      console.log("  （无插件依赖，仅内核 bundle）");
      process.exit(0);
    }
    let nb = 0;
    const rows = names.map((n) => {
      const isB = bundles.has(n);
      if (isB) nb += 1;
      let kind = "依赖";
      if (isB) kind = n.startsWith("@deepseek-ai/") ? "bundle（内核）" : "bundle（外装）";
      return { n, kind, src: deps[n] || "" };
    });
    const w = Math.max(...rows.map((r) => r.n.length), 16);
    for (const r of rows) {
      console.log("  " + r.n.padEnd(w) + "  " + r.kind + "  " + r.src);
    }
    console.log("  合计: " + rows.length + " 个依赖（" + nb + " 个 bundle）");
  ' "$dir/package.json" || die "读取插件清单失败: $dir/package.json"
}

maybe_restart_service() { # $1=变更描述（默认"插件变更"） $2=force（1=当前未检测到服务也按"曾运行"处理）
  local what="${1:-插件变更}" force="${2:-0}"
  local mode
  mode="$(service_mode)"
  if [ "$mode" = "none" ] && [ "$force" -ne 1 ]; then
    info "当前没有运行中的服务；${what}将在下次启动时生效。"
    return 0
  fi
  local do_it=0
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    do_it=1
    info "${what}需重启服务才生效（-y / 非交互环境：自动重启）"
  else
    printf '%s需重启服务才生效，现在重启？[Y/n] ' "$what"
    local ans=""
    read -r ans || true
    case "$ans" in
      n|N|no|NO|No) do_it=0 ;;
      *)            do_it=1 ;;
    esac
  fi
  if [ "$do_it" -eq 1 ]; then
    SERVICE_ACTION="restart"
    do_service_action
    SERVICE_ACTION=""
  else
    info "已跳过重启；可稍后执行: dshctl --restart"
  fi
}

maybe_restart_after_plugin_change() {
  maybe_restart_service "插件变更"
}

do_plugin_action() {
  local profile="$PLUGIN_PROFILE"
  resolve_effective_port

  if [ "$PLUGIN_ACTION" = "list" ]; then
    do_plugin_list
    return 0
  fi

  local action_cn=""
  case "$PLUGIN_ACTION" in
    add)    action_cn="安装" ;;
    remove) action_cn="卸载" ;;
    update) action_cn="更新" ;;
    why)    action_cn="溯源" ;;
    repair) action_cn="修复" ;;
    policy) action_cn="审计" ;;
    policy-set) action_cn="设置" ;;
    policy-reset) action_cn="恢复" ;;
  esac

  if [ "$DRY_RUN" -eq 1 ] && [ "$PLUGIN_ACTION" != "policy" ]; then
    case "$PLUGIN_ACTION" in
      repair)       info "[dry-run] 将执行: dsh plugin --profile $profile clean --lockfile && dsh plugin --profile $profile install" ;;
      policy-set)   info "[dry-run] 将执行: dsh plugin --profile $profile config set minimumReleaseAge ${PLUGIN_SPECS[0]:-?} --location project" ;;
      policy-reset) info "[dry-run] 将执行: dsh plugin --profile $profile config delete minimumReleaseAge --location project" ;;
      *)            info "[dry-run] 将执行: dsh plugin --profile $profile $PLUGIN_ACTION ${PLUGIN_SPECS[*]:-}" ;;
    esac
    return 0
  fi

  require_cmd_launcher
  [ -d "$DSH_DIR/.git" ] || die "源码目录不存在或不是 git 仓库: ${DSH_DIR}（请先运行 --install）"

  case "$PLUGIN_ACTION" in
    policy)       do_plugin_policy; return 0 ;;
    policy-set)   do_plugin_policy_set; return 0 ;;
    policy-reset) do_plugin_policy_reset; return 0 ;;
  esac

  local -a specs=()
  local s
  case "$PLUGIN_ACTION" in
    add|remove)
      for s in ${PLUGIN_SPECS[@]+"${PLUGIN_SPECS[@]}"}; do
        specs+=("$(resolve_plugin_spec "$s")")
      done
      ;;
    update|why)
      specs=(${PLUGIN_SPECS[@]+"${PLUGIN_SPECS[@]}"})
      ;;
  esac
  if [ "$PLUGIN_ACTION" = "why" ] && [ "${#specs[@]}" -ne 1 ]; then
    die "--plugin-why 只接受一个插件名（收到 ${#specs[@]} 个）"
  fi

  case "$PLUGIN_ACTION" in
    add)
      warn "安装插件 = 引入可执行代码，请确认来源可信。"
      info "安装插件: ${specs[*]+"${specs[*]}"}"
      ;;
    remove) info "卸载插件: ${specs[*]+"${specs[*]}"}" ;;
    update)
      if [ "${#specs[@]}" -gt 0 ]; then info "更新插件: ${specs[*]+"${specs[*]}"}"; else info "更新全部插件..."; fi
      ;;
    why)    info "依赖溯源: ${specs[0]}" ;;
    repair) info "重建 profile 锁文件（pnpm clean --lockfile + pnpm install）..." ;;
  esac

  if [ "$PLUGIN_ACTION" = "remove" ]; then
    plugin_precheck_remove ${PLUGIN_SPECS[@]+"${PLUGIN_SPECS[@]}"}
  fi

  local rc=0
  case "$PLUGIN_ACTION" in
    add)    plugin_run "$profile" add ${specs[@]+"${specs[@]}"} || rc=$? ;;
    remove) plugin_run "$profile" remove ${specs[@]+"${specs[@]}"} || rc=$? ;;
    update) plugin_run "$profile" update ${specs[@]+"${specs[@]}"} || rc=$? ;;
    why)    plugin_run "$profile" why "${specs[0]}" || rc=$? ;;
    repair)
      plugin_run "$profile" clean --lockfile || rc=$?
      if [ "$rc" -eq 0 ]; then
        plugin_run "$profile" install || rc=$?
      fi
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    plugin_failure_hint
    die "插件${action_cn}失败（退出码 ${rc}，详见上方输出）。"
  fi

  case "$PLUGIN_ACTION" in
    add|remove|update|repair)
      ok "插件${action_cn}完成（profile: ${profile}）"
      maybe_restart_after_plugin_change
      ;;
  esac
}

# -----------------------------------------------------------------------------
# 模型维护（配置查看 / 连通自检 / 0.1.6 Messages 协议误配修复）
# -----------------------------------------------------------------------------
mask_secret() {
  local v="$1"
  [ -n "$v" ] || return 0
  if [ "${#v}" -le 10 ]; then
    printf '****'
  else
    printf '%s****%s' "${v:0:4}" "${v: -4}"
  fi
}

read_env_var() { # $1=文件 $2=变量名；无匹配/不可读时返回空且 rc=0
  [ -f "$1" ] || return 0
  sed -nE "s/^[[:space:]]*$2=(.*)$/\1/p" "$1" 2>/dev/null | tail -n1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" || true
  return 0
}

read_yaml_value() { # $1=文件 $2=键名正则（大小写不敏感）；无匹配/不可读时返回空且 rc=0
  [ -f "$1" ] || return 0
  { grep -iE "^[[:space:]]*($2)[[:space:]]*:" "$1" 2>/dev/null | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//' | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" ; } || true
  return 0
}

read_settings_llm_value() { # $1=settings.yaml $2=键名（如 baseURL / protocol）；读取 llm-deepseek 段
  local f="$1" key="$2"
  [ -f "$f" ] || return 0
  awk -v key="$key" '
    /^[^[:space:]#]/ {
      s = $0
      sub(/:.*/, ":", s)
      section = s
    }
    section == "llm-deepseek:" && $0 ~ "^[[:space:]]+" key ":" {
      sub("^[[:space:]]+" key ":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$f" 2>/dev/null || true
  return 0
}

# 写入 $DSH_HOME/settings.yaml 的 llm-deepseek.baseURL（dsh 0.1.6+ 唯一合法的配置文件位置）
settings_write_baseurl() {
  local url="$1" f="$DSH_HOME_ABS/settings.yaml"
  mkdir -p "$DSH_HOME_ABS" 2>/dev/null || return 1
  if [ ! -f "$f" ]; then
    printf 'llm-deepseek:\n  baseURL: %s\n' "$url" > "$f" || return 1
    return 0
  fi
  local has_section=0 has_key=0
  if grep -qE '^llm-deepseek:[[:space:]]*$' "$f" 2>/dev/null; then has_section=1; fi
  if [ "$has_section" -eq 1 ] && awk '/^[^[:space:]]/{s=$0} s=="llm-deepseek:" && $0 ~ "^[[:space:]]+baseURL:" {found=1} END{exit !found}' "$f" 2>/dev/null; then
    has_key=1
  fi
  if [ "$has_key" -eq 1 ]; then
    awk -v url="$url" '
      /^[^[:space:]]/ { s = $0 }
      s == "llm-deepseek:" && $0 ~ "^[[:space:]]+baseURL:" { print "  baseURL: " url; next }
      { print }
    ' "$f" > "$f.tmp" && mv -f -- "$f.tmp" "$f" || return 1
  elif [ "$has_section" -eq 1 ]; then
    awk -v url="$url" '
      { print }
      /^[^[:space:]]/ { if ($0 == "llm-deepseek:") { print "  baseURL: " url } }
    ' "$f" > "$f.tmp" && mv -f -- "$f.tmp" "$f" || return 1
  else
    printf '\nllm-deepseek:\n  baseURL: %s\n' "$url" >> "$f" || return 1
  fi
  return 0
}

# 列出 .env 文件中「未注释」的 DEEPSEEK_BASE_URL 值（0.1.6+ 禁止项）
env_baseurl_values() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -nE 's/^[[:space:]]*DEEPSEEK_BASE_URL=(.*)$/\1/p' "$f" 2>/dev/null || true
  return 0
}

# 注释 .env 文件中所有未注释的 DEEPSEEK_BASE_URL 行（调用方负责备份）
env_comment_baseurl() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -i -E 's~^([[:space:]]*)(DEEPSEEK_BASE_URL=.*)$~\1# \2~' "$f" || return 1
  return 0
}

# 输出 .env 中的非法 base 配置（每行: 非法位置 <文件>|值）
model_illegal_env_bases() {
  local f v
  for f in "$DSH_DIR/.env" "$DSH_HOME_ABS/.env"; do
    [ -f "$f" ] || continue
    while IFS= read -r v; do
      [ -n "$v" ] && printf '非法位置 %s|%s\n' "$f" "$v"
    done < <(env_baseurl_values "$f")
  done
  return 0
}

is_old_official_root() {
  local u="${1%/}"
  case "$u" in
    "https://api.deepseek.com"|"http://api.deepseek.com"|"https://api.deepseek.com/v1"|"http://api.deepseek.com/v1"|"https://api.deepseek.com/beta") return 0 ;;
  esac
  return 1
}

installed_dsh_version() {
  local f v
  for f in "$DSH_DIR/apps/cli/package.json" "$DSH_DIR/package.json"; do
    [ -f "$f" ] || continue
    v="$(node -e 'const j=require(process.argv[1]);process.stdout.write(j.version||"")' "$f" 2>/dev/null || true)"
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 1
}

# dsh >= 0.1.6 默认启用 Messages 协议
version_has_messages_protocol() {
  local v="${1%%-*}" major minor patch
  IFS=. read -r major minor patch <<< "$v"
  major="${major//[!0-9]/}"; minor="${minor//[!0-9]/}"; patch="${patch//[!0-9]/}"
  [ -n "$major" ] || return 1
  if [ "$major" -gt 0 ]; then return 0; fi
  if [ "$minor" -gt 1 ]; then return 0; fi
  if [ "$minor" -lt 1 ]; then return 1; fi
  [ "${patch:-0}" -ge 6 ] && return 0
  return 1
}

# 查找不合规的 Base URL 配置（输出每行: 来源|值；覆盖 settings/环境变量/.env 非法位置/补丁）
model_old_root_findings() {
  local v f hit
  v="$(read_settings_llm_value "$DSH_HOME_ABS/settings.yaml" baseURL)"
  if [ -n "$v" ] && is_old_official_root "$v"; then
    printf '设置文件 %s|%s\n' "$DSH_HOME_ABS/settings.yaml" "$v"
  fi
  if [ -n "${DEEPSEEK_BASE_URL:-}" ] && is_old_official_root "$DEEPSEEK_BASE_URL"; then
    printf '环境变量 DEEPSEEK_BASE_URL|%s\n' "$DEEPSEEK_BASE_URL"
  fi
  model_illegal_env_bases
  for f in "$DSH_HOME_ABS/cordis.patch.yml" "$PROFILES_DIR/$PLUGIN_PROFILE/cordis.patch.yml"; do
    [ -f "$f" ] || continue
    hit="$(grep -n "api\.deepseek\.com" "$f" 2>/dev/null | grep -v "anthropic" | head -n1 || true)"
    [ -n "$hit" ] && printf '补丁文件 %s|%s\n' "$f" "$hit"
  done
  return 0
}

model_compat_check_warn() {
  local ver="" findings=""
  ver="$(installed_dsh_version || true)"
  [ -n "$ver" ] || return 0
  version_has_messages_protocol "$ver" || return 0
  findings="$(model_old_root_findings)"
  [ -n "$findings" ] || return 0
  warn "模型配置兼容性: dsh 0.1.6+ 仅允许从 settings.yaml 或启动环境设置 Base URL；检测到以下问题："
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && warn "  · $l"
  done <<< "$findings"
  warn "可执行 dshctl --model-fix 修复（.env 非法项自动注释并备份）。"
  return 0
}

do_model_show() {
  step "模型配置总览"
  local ver=""
  ver="$(installed_dsh_version || true)"
  if [ -n "$ver" ]; then
    if version_has_messages_protocol "$ver"; then
      printf '  dsh 版本   : %s（Messages 协议，0.1.6+）\n' "$ver"
    else
      printf '  dsh 版本   : %s（旧协议）\n' "$ver"
    fi
  else
    printf '  dsh 版本   : 未知（源码未安装或不可读）\n'
  fi

  local sproto=""
  sproto="$(read_settings_llm_value "$DSH_HOME_ABS/settings.yaml" protocol)"
  if [ -n "$sproto" ]; then
    printf '  协议覆盖   : %s（来源: 设置文件）\n' "$sproto"
    if [ "$sproto" = "chat-completions" ]; then
      printf '               （Chat 协议默认端点 https://api.deepseek.com；请确认 Base URL 与之匹配）\n'
    fi
  fi

  local creds="$DSH_HOME_ABS/.credentials.yaml"
  local ksrc="" kval="" k
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then ksrc="环境变量"; kval="$DEEPSEEK_API_KEY"; fi
  if [ -z "$kval" ]; then
    k="$(read_yaml_value "$creds" 'api_?key|apikey|api-key')"
    if [ -n "$k" ]; then ksrc="凭据文件"; kval="$k"; fi
  fi
  if [ -z "$kval" ]; then
    k="$(read_env_var "$DSH_DIR/.env" DEEPSEEK_API_KEY)"
    if [ -n "$k" ]; then ksrc="项目 .env"; kval="$k"; fi
  fi
  if [ -z "$kval" ]; then
    k="$(read_env_var "$DSH_HOME_ABS/.env" DEEPSEEK_API_KEY)"
    if [ -n "$k" ]; then ksrc="$DSH_HOME_DISPLAY/.env"; kval="$k"; fi
  fi
  if [ -n "$kval" ]; then
    printf '  API Key    : %s（来源: %s）\n' "$(mask_secret "$kval")" "$ksrc"
  else
    printf '  API Key    : 未配置（可在 Web UI 设置 → 模型 中填写）\n'
  fi

  local bsrc="" bval="" eff_b
  eff_b="$(model_effective_base)"
  bsrc="${eff_b%%|*}"; bval="${eff_b#*|}"
  if [ "$bsrc" = "设置文件" ]; then bsrc="设置文件 settings.yaml"; fi
  if [ -n "$bval" ]; then
    if is_old_official_root "$bval"; then
      printf '  Base URL   : %s（来源: %s）⚠ 旧官方根地址\n' "$bval" "$bsrc"
    else
      printf '  Base URL   : %s（来源: %s）\n' "$bval" "$bsrc"
    fi
  else
    printf '  Base URL   : 未显式配置（使用 dsh 官方默认端点）\n'
  fi
  local illegal_b=""
  illegal_b="$(model_illegal_env_bases)"
  if [ -n "$illegal_b" ]; then
    local il
    while IFS= read -r il; do
      [ -n "$il" ] && warn "  ⚠ 无效配置 : ${il%%|*} 设置了 DEEPSEEK_BASE_URL=${il##*|}（dsh 0.1.6+ 会拒绝启动；--model-fix 可修复）"
    done <<< "$illegal_b"
  fi
  printf '  Base 优先级: settings.yaml(llm-deepseek) > 启动环境变量 > 协议默认（.env 中设置会被拒绝启动）\n'
  printf '  Key 优先级 : 环境变量 > 凭据文件 > 项目 .env > ~/.dsh/.env\n'

  local f
  local -a exist_files=()
  for f in "$DSH_HOME_ABS/settings.yaml" "$DSH_DIR/.env" "$DSH_HOME_ABS/.env" "$creds"; do
    [ -f "$f" ] && exist_files+=("$f")
  done
  if [ "${#exist_files[@]}" -gt 0 ]; then
    printf '  配置文件   : %s\n' "${exist_files[*]}"
  fi

  local findings=""
  findings="$(model_old_root_findings)"
  if [ -n "$findings" ]; then
    printf '\n'
    if [ -n "$ver" ] && version_has_messages_protocol "$ver"; then
      warn "检测到不合规的 Base URL 配置（0.1.6+ 仅允许 settings.yaml/启动环境）："
    else
      warn "检测到旧官方根地址配置（升级到 0.1.6+ 后将导致启动失败）："
    fi
    local l
    while IFS= read -r l; do
      [ -n "$l" ] && warn "  · $l"
    done <<< "$findings"
    warn "可执行: dshctl --model-fix"
  else
    ok "未发现不合规的 Base URL 配置。"
  fi
}

do_model_check() {
  step "模型连通性自检"
  require_cmd_launcher
  [ -d "$DSH_DIR/.git" ] || die "源码目录不存在或不是 git 仓库: ${DSH_DIR}（请先运行 --install）"

  local have_key=0
  if [ -n "${DEEPSEEK_API_KEY:-}" ]; then have_key=1; fi
  if [ "$have_key" -eq 0 ] && [ -n "$(read_yaml_value "$DSH_HOME_ABS/.credentials.yaml" 'api_?key|apikey|api-key')" ]; then have_key=1; fi
  if [ "$have_key" -eq 0 ] && [ -n "$(read_env_var "$DSH_DIR/.env" DEEPSEEK_API_KEY)" ]; then have_key=1; fi
  if [ "$have_key" -eq 0 ] && [ -n "$(read_env_var "$DSH_HOME_ABS/.env" DEEPSEEK_API_KEY)" ]; then have_key=1; fi
  if [ "$have_key" -eq 0 ]; then
    warn "未检测到任何 API Key（环境变量/.env/凭据文件），自检可能失败。"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将执行: dsh headless \"回复 OK 即可\""
    return 0
  fi

  info "发送一条最小测试消息（headless，消耗少量 token）..."
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 "$HOME/.local/bin/dsh" headless "回复 OK 即可" || rc=$?
  else
    "$HOME/.local/bin/dsh" headless "回复 OK 即可" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    ok "模型调用成功，配置可用。"
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    warn "自检超时（180 秒）：可能是网络/代理或端点不可达。"
  else
    warn "自检失败（退出码 ${rc}）。排查建议："
    warn "  1) dshctl --model-show 查看 key/地址来源与兼容性；"
    warn "  2) dshctl --model-fix 修复旧官方根地址（0.1.6+ 协议变更）；"
    warn "  3) 检查网络/代理，或 --logs 查看服务日志。"
    local recent=""
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
      recent="$(tail -n 80 -- "$LOG_FILE" 2>/dev/null || true)"
    fi
    case "$recent" in
      *HTTP_404*)
        warn "  4) 服务端返回 404（Messages 端点路径不存在）：通常是有处覆盖了 Base URL（指向旧官方根地址）。"
        warn "     请把 Base URL 改为 https://api.deepseek.com/anthropic 或移除该覆盖（--model-show 显示来源与优先级）；"
        warn "     使用第三方网关时请填写其 Anthropic 兼容地址。"
        ;;
      *HTTP_401*|*HTTP_403*|*MISSING_CREDENTIAL*|*INVALID_CREDENTIAL*)
        warn "  4) 凭据问题（401/403 或缺失/无效）：请按 --model-show 显示的 Key 来源核对密钥有效性。"
        ;;
    esac
  fi
  die "模型连通性自检失败。"
}

do_model_fix() {
  local repo_env="$DSH_DIR/.env" home_env="$DSH_HOME_ABS/.env"
  local -a fix_files=() manual=()
  local f val

  # 可自动修复：.env 中的 DEEPSEEK_BASE_URL（任何值都非法，0.1.6+ 会拒绝启动）
  for f in "$repo_env" "$home_env"; do
    [ -f "$f" ] || continue
    while IFS= read -r val; do
      [ -n "$val" ] && fix_files+=("$f|$val")
    done < <(env_baseurl_values "$f")
  done
  # 需手动：settings/环境变量中的旧官方根地址、补丁文件
  local fl=""
  while IFS= read -r fl; do
    [ -n "$fl" ] || continue
    case "$fl" in
      非法位置*) continue ;;
    esac
    manual+=("$fl")
  done <<< "$(model_old_root_findings)"

  if [ "${#fix_files[@]}" -eq 0 ] && [ "${#manual[@]}" -eq 0 ]; then
    ok "未发现不合规的 Base URL 配置，无需修复。"
    return 0
  fi

  step "Base URL 配置修复"
  local item
  for item in ${fix_files[@]+"${fix_files[@]}"}; do
    printf '  将修复   : %s（当前值: %s；注释后 dsh 可正常启动）\n' "${item%%|*}" "${item##*|}"
  done
  for item in ${manual[@]+"${manual[@]}"}; do
    printf '  需手动   : %s（当前值: %s）\n' "${item%%|*}" "${item##*|}"
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上为预览，未做任何改动。"
    return 0
  fi

  if [ "${#fix_files[@]}" -gt 0 ]; then
    if ! confirm_config_change "确认注释 .env 中的 DEEPSEEK_BASE_URL（修改前自动备份）？"; then
      die "已取消（未修改配置）。"
    fi
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    for item in ${fix_files[@]+"${fix_files[@]}"}; do
      f="${item%%|*}"; val="${item##*|}"
      cp -a -- "$f" "$f.bak.$ts" 2>/dev/null || die "备份失败: $f"
      env_comment_baseurl "$f" || die "修改失败: $f"
      ok "已修复: ${f}（备份: $f.bak.${ts}）"
      local old_bak
      while IFS= read -r old_bak; do
        rm -f -- "$old_bak" 2>/dev/null || true
      done < <(ls -1t "$f".bak.* 2>/dev/null | tail -n +4)
      if ! is_old_official_root "$val"; then
        info "原值 $val 如仍需使用，请写入合法位置: dshctl --model-set-base $val"
      fi
    done
    info "提示：Base URL 的合法位置是 settings.yaml（llm-deepseek.baseURL）或启动环境变量；"
    info "      写入 settings.yaml 可用: dshctl --model-set-base <地址>"
    info "修复后建议: dshctl --model-check"
  fi
  if [ "${#manual[@]}" -gt 0 ]; then
    warn "以下位置无法自动修改，请手动处理："
    local settings_hit=0 env_hit=0 patch_hit=0
    for item in ${manual[@]+"${manual[@]}"}; do
      warn "  · ${item%%|*}（当前值: ${item##*|}）"
      case "${item%%|*}" in
        设置文件*) settings_hit=1 ;;
        环境变量*) env_hit=1 ;;
        补丁文件*) patch_hit=1 ;;
      esac
    done
    if [ "$settings_hit" -eq 1 ]; then
      warn "  → 设置文件：可执行 dshctl --model-set-base https://api.deepseek.com/anthropic 覆盖；"
      warn "     或在 Web UI「设置 → 模型 → DeepSeek 卡片」中修改/清空（dsh 热读取，无需重启）。"
    fi
    if [ "$env_hit" -eq 1 ]; then
      warn "  → 环境变量：请在 shell 配置中移除（unset DEEPSEEK_BASE_URL）。"
    fi
    if [ "$patch_hit" -eq 1 ]; then
      warn "  → 补丁文件：请编辑对应 cordis.patch.yml 中的 api.deepseek.com 引用（改为 .../anthropic 或移除）。"
    fi
  fi
  return 0
}

# 升级前数据保护：源码版本变化时自动备份 $DSH_HOME（保留最近 3 份）
preupgrade_backup_if_needed() {
  [ "$DO_BACKUP" -eq 1 ] || return 0
  [ -d "$DSH_HOME_ABS" ] || return 0
  [ -n "$(ls -A "$DSH_HOME_ABS" 2>/dev/null)" ] || return 0
  local new_head="${REPO_HEAD:-}"
  [ -n "$new_head" ] || return 0
  local prev_head=""
  if [ -f "$STATE_INSTALL_HEAD_FILE" ]; then
    prev_head="$(cat "$STATE_INSTALL_HEAD_FILE" 2>/dev/null || true)"
  fi
  if [ "$prev_head" = "$new_head" ]; then
    return 0
  fi
  local reason="源码版本变化"
  if [ -z "$prev_head" ]; then reason="首次由 dshctl 管理，保护既有数据"; fi
  local backup_file ts
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_file="$HOME/dshctl-preupgrade-$ts.tar.gz"
  info "升级前数据保护（${reason}）：备份 $DSH_HOME_ABS → $backup_file"
  if tar -czf "$backup_file" -C "$(dirname -- "$DSH_HOME_ABS")" "$(basename -- "$DSH_HOME_ABS")" 2>/dev/null; then
    chmod 600 "$backup_file" 2>/dev/null || true
    ok "已备份: $backup_file"
    local old
    while IFS= read -r old; do
      rm -f -- "$old" 2>/dev/null || true
    done < <(ls -1t "$HOME"/dshctl-preupgrade-*.tar.gz 2>/dev/null | tail -n +4)
  else
    warn "备份失败（数据未被修改；请检查磁盘空间后手动备份）：$backup_file"
  fi
  return 0
}

record_install_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local ver=""
  ver="$(installed_dsh_version || true)"
  if [ -n "$ver" ]; then
    printf '%s' "$ver" > "$STATE_INSTALL_VERSION_FILE" 2>/dev/null || true
  fi
  if [ -n "${REPO_HEAD:-}" ]; then
    printf '%s' "$REPO_HEAD" > "$STATE_INSTALL_HEAD_FILE" 2>/dev/null || true
    local last_head=""
    if [ -f "$STATE_INSTALL_HISTORY_FILE" ]; then
      last_head="$(tail -n1 -- "$STATE_INSTALL_HISTORY_FILE" 2>/dev/null | cut -d'|' -f3 || true)"
    fi
    if [ "$last_head" != "$REPO_HEAD" ]; then
      printf '%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${ver:-未知}" "$REPO_HEAD" "${DSH_REF:-master}" >> "$STATE_INSTALL_HISTORY_FILE" 2>/dev/null || true
      local cnt=""
      cnt="$(wc -l < "$STATE_INSTALL_HISTORY_FILE" 2>/dev/null || echo 0)"
      if [ "${cnt:-0}" -gt 5 ]; then
        tail -n 5 -- "$STATE_INSTALL_HISTORY_FILE" > "$STATE_INSTALL_HISTORY_FILE.tmp" 2>/dev/null \
          && mv -f -- "$STATE_INSTALL_HISTORY_FILE.tmp" "$STATE_INSTALL_HISTORY_FILE" 2>/dev/null || true
      fi
    fi
  fi
  return 0
}

# -----------------------------------------------------------------------------
# 数据维护（$DSH_HOME 备份 / 恢复 / 会话归档 / 缓存清理）
# -----------------------------------------------------------------------------
data_home_size() {
  [ -e "$1" ] || return 0
  du -sh -- "$1" 2>/dev/null | cut -f1
}

do_data_backup() {
  step "备份运行数据（${DSH_HOME_ABS}）"
  if [ ! -d "$DSH_HOME_ABS" ] || [ -z "$(ls -A "$DSH_HOME_ABS" 2>/dev/null)" ]; then
    info "运行数据目录为空或不存在，无需备份。"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将备份 ${DSH_HOME_ABS}（$(data_home_size "$DSH_HOME_ABS")）。"
    return 0
  fi
  local mode
  mode="$(service_mode)"
  if [ "$mode" != "none" ]; then
    warn "检测到服务正在运行（${mode}）；运行中备份可能包含未落盘数据，建议先 dshctl --stop。"
    if ! confirm_config_change "服务运行中，仍要现在备份吗？"; then
      die "已取消备份。"
    fi
  fi
  local ts backup_file
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_file="$HOME/dshctl-backup-$ts.tar.gz"
  info "正在打包（profiles / sessions / storages / 凭据）..."
  if tar -czf "$backup_file" -C "$(dirname -- "$DSH_HOME_ABS")" "$(basename -- "$DSH_HOME_ABS")" 2>/dev/null; then
    chmod 600 "$backup_file" 2>/dev/null || true
    ok "备份完成: ${backup_file}（$(data_home_size "$backup_file")）"
    info "恢复: dshctl --data-restore \"$backup_file\""
  else
    rm -f -- "$backup_file" 2>/dev/null || true
    die "备份失败（请检查磁盘空间）。"
  fi
}

do_data_restore() {
  local archive="$DATA_ARCHIVE"
  step "从备份恢复运行数据"
  [ -f "$archive" ] || die "备份文件不存在: $archive"
  tar -tzf "$archive" >/dev/null 2>&1 || die "不是有效的 tar.gz 备份: $archive"

  local tmp
  tmp="$(mktemp -d 2>/dev/null)" || die "无法创建临时目录。"
  tar -xzf "$archive" -C "$tmp" || { rm -rf -- "$tmp"; die "解压失败。"; }
  local src=""
  if [ -d "$tmp/.dsh" ]; then
    src="$tmp/.dsh"
  else
    local entries n
    entries="$(ls -A "$tmp" 2>/dev/null | head -n 2)"
    n="$(printf '%s\n' "$entries" | grep -c . || true)"
    if [ "${n:-0}" = "1" ] && [ -d "$tmp/$entries" ]; then
      src="$tmp/$entries"
    fi
  fi
  if [ -z "$src" ]; then
    rm -rf -- "$tmp"
    die "无法识别备份结构（期望顶层为 .dsh/ 或单一目录）。"
  fi
  info "备份内容: $(du -sh "$src" 2>/dev/null | cut -f1)（将覆盖 ${DSH_HOME_ABS}）"

  if [ "$DRY_RUN" -eq 1 ]; then
    rm -rf -- "$tmp"
    info "[dry-run] 以上为预览，未做任何改动。"
    return 0
  fi
  if ! confirm_config_change "确认用该备份覆盖当前运行数据（${DSH_HOME_ABS}）？恢复前会自动备份现状。"; then
    rm -rf -- "$tmp"
    die "已取消恢复。"
  fi

  local was_running=0
  if [ "$(service_mode)" != "none" ]; then was_running=1; fi
  if [ "$was_running" -eq 1 ]; then
    info "先停止服务（避免写入冲突）..."
    SERVICE_ACTION="stop"
    do_service_action || true
    SERVICE_ACTION=""
  fi
  if [ -d "$DSH_HOME_ABS" ] && [ -n "$(ls -A "$DSH_HOME_ABS" 2>/dev/null)" ]; then
    local ts pre
    ts="$(date +%Y%m%d-%H%M%S)"
    pre="$HOME/dshctl-backup-$ts.tar.gz"
    if tar -czf "$pre" -C "$(dirname -- "$DSH_HOME_ABS")" "$(basename -- "$DSH_HOME_ABS")" 2>/dev/null; then
      chmod 600 "$pre" 2>/dev/null || true
      ok "现状已备份: $pre"
    else
      rm -rf -- "$tmp"
      die "现状备份失败，已中止恢复（数据未动）。"
    fi
  fi
  safe_rm_rf "$DSH_HOME_ABS" "DSH_HOME 运行数据"
  mkdir -p "$(dirname -- "$DSH_HOME_ABS")"
  if ! mv -- "$src" "$DSH_HOME_ABS"; then
    rm -rf -- "$tmp"
    die "恢复失败: 无法移动到 $DSH_HOME_ABS"
  fi
  rm -rf -- "$tmp"
  ok "恢复完成: ${DSH_HOME_ABS}（$(data_home_size "$DSH_HOME_ABS")）"
  if [ "$was_running" -eq 1 ]; then
    maybe_restart_service "数据恢复" 1
  else
    info "可执行 dshctl --start 启动服务。"
  fi
}

do_data_archive_sessions() {
  step "归档旧会话（解决升级后会话不兼容）"
  local sess="$DSH_HOME_ABS/sessions"
  if [ ! -d "$sess" ] || [ -z "$(ls -A "$sess" 2>/dev/null)" ]; then
    info "会话目录为空或不存在（${sess}），无需归档。"
    return 0
  fi
  local ts dest
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$DSH_HOME_ABS/sessions-archive-$ts"
  warn "将把 $sess 整体移动到: ${dest}（数据不删除，可手动移回）"
  warn "注意：dsh 的会话/归档列表可能残留失效条目，可在 Web UI「设置 → 已归档会话」中清理。"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上为预览，未做任何改动。"
    return 0
  fi
  if ! confirm_config_change "确认归档旧会话？（建议先 dshctl --stop）"; then
    die "已取消。"
  fi
  local was_running=0
  if [ "$(service_mode)" != "none" ]; then was_running=1; fi
  if [ "$was_running" -eq 1 ]; then
    SERVICE_ACTION="stop"
    do_service_action || true
    SERVICE_ACTION=""
  fi
  if ! mv -- "$sess" "$dest"; then
    die "归档失败（请检查权限）。"
  fi
  ok "已归档: ${dest}（$(du -sh "$dest" 2>/dev/null | cut -f1)）"
  if [ "$was_running" -eq 1 ]; then
    maybe_restart_service "会话归档" 1
  else
    info "可执行 dshctl --start 启动服务。"
  fi
}

do_data_prune() {
  step "清理可重建缓存"
  local img_cache="$DSH_HOME_ABS/cache/attachments/request-images"
  local found=0
  if [ -d "$img_cache" ]; then
    printf '  图片请求缓存 : %s（%s，删除后按需重建）\n' "$img_cache" "$(du -sh "$img_cache" 2>/dev/null | cut -f1)"
    found=1
  else
    printf '  图片请求缓存 : 不存在（%s）\n' "$img_cache"
  fi
  if [ "$found" -eq 0 ]; then
    info "没有可清理的缓存项。"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上为预览，未做任何改动。"
    return 0
  fi
  if ! confirm_config_change "确认删除上述缓存？"; then
    die "已取消。"
  fi
  safe_rm_rf "$img_cache" "图片请求缓存"
  ok "已清理: $img_cache"
  info "如需清理 pnpm 共享缓存请手动执行: pnpm store prune"
}

# -----------------------------------------------------------------------------
# 版本管理（历史 / 回退 / 升级检查）
# -----------------------------------------------------------------------------
version_ge() { # $1 >= $2（只比较前三个数字段，忽略预发布后缀）
  local a="${1%%-*}" b="${2%%-*}" i
  local -a av bv
  IFS=. read -r -a av <<< "$a"
  IFS=. read -r -a bv <<< "$b"
  for i in 0 1 2; do
    local x="${av[$i]:-0}" y="${bv[$i]:-0}"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    x="${x:-0}"; y="${y:-0}"
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

do_upgrade_check() {
  step "版本检查（本地 vs 上游）"
  local ver="" head=""
  ver="$(installed_dsh_version || true)"
  if [ -n "$ver" ]; then
    printf '  本地 dsh   : %s\n' "$ver"
  else
    printf '  本地 dsh   : 未安装\n'
  fi
  if [ ! -d "$DSH_DIR/.git" ]; then
    info "源码目录不存在，无法比较上游版本（请先 --install）。"
    return 0
  fi
  head="$(git -C "$DSH_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  printf '  源码 HEAD  : %s\n' "${head:-未知}"
  info "查询上游（git ls-remote）..."
  local tags latest_tag="" latest_ver="" remote_head="" local_head=""
  tags="$(git -C "$DSH_DIR" ls-remote --tags origin 'dsh-v*' 2>/dev/null || true)"
  if [ -n "$tags" ]; then
    latest_tag="$(printf '%s\n' "$tags" | grep -vF '^{}' | sed -E 's#.*refs/tags/(dsh-v[^ ]*).*#\1#' | sort -V | tail -n1)"
    latest_ver="${latest_tag#dsh-v}"
    printf '  上游最新tag: %s\n' "$latest_tag"
    if [ -n "$ver" ]; then
      if version_ge "$ver" "$latest_ver"; then
        printf '  结论       : 本地不低于上游最新 tag\n'
      else
        printf '  结论       : 上游有更新版本（可 dshctl --install 升级）\n'
      fi
    fi
  else
    warn "未能获取上游 tag 列表（网络/代理问题？）。"
  fi
  remote_head="$(git -C "$DSH_DIR" ls-remote origin HEAD 2>/dev/null | awk '{print $1}' || true)"
  local_head="$(git -C "$DSH_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$remote_head" ]; then
    if [ "$remote_head" = "$local_head" ]; then
      printf '  master     : 与上游一致\n'
    else
      printf '  master     : 上游有新提交（%s → %s）\n' "${head:-?}" "${remote_head:0:12}"
      info "升级: dshctl --install；回退: dshctl --rollback"
    fi
  fi
  return 0
}

rollback_prev_target() { # 输出上一次与当前 HEAD 不同的历史提交；无则空
  [ -f "$STATE_INSTALL_HISTORY_FILE" ] || return 0
  local cur=""
  cur="$(git -C "$DSH_DIR" rev-parse HEAD 2>/dev/null || true)"
  awk -F'|' -v cur="$cur" '$3 != "" && $3 != cur { last = $3 } END { if (last) print last }' "$STATE_INSTALL_HISTORY_FILE" 2>/dev/null || true
  return 0
}

do_rollback_prepare() {
  step "回退到历史版本"
  [ -d "$DSH_DIR/.git" ] || die "源码目录不存在: ${DSH_DIR}（请先 --install）"
  local target="$ROLLBACK_REF"
  if [ -z "$target" ]; then
    target="$(rollback_prev_target)"
    [ -n "$target" ] || die "未找到可回退的历史版本（需至少一次由 dshctl 完成的安装，且历史中有不同版本）。"
  fi
  local short=""
  short="$(git -C "$DSH_DIR" rev-parse --short "$target" 2>/dev/null || true)"
  info "回退目标: $target${short:+（本地已有提交 ${short}）}"
  warn "注意：回退只改源码版本，不会回滚 ~/.dsh 运行数据；新版本写入的数据可能与旧版本不兼容。"
  warn "      建议先执行: dshctl --data-backup"
  if ! confirm_config_change "确认回退到该版本并重新构建？"; then
    die "已取消回退。"
  fi
  DSH_REF="$target"
  FORCE_REBUILD=1
  DO_INSTALL_DEPS=1
  DO_BUILD=1
  info "将执行: 切换到 $DSH_REF → pnpm install → pnpm run build（升级前自动备份照常触发）"
  return 0
}

# -----------------------------------------------------------------------------
# 访问助手 / 备份管理 / 模型地址切换
# -----------------------------------------------------------------------------
do_url() {
  step "Web UI 访问地址"
  [ -f "$WEB_LOG_FILE" ] || die "未找到服务日志（${WEB_LOG_FILE}）；请先 dshctl --start。"
  local url=""
  url="$(grep -Eo 'http://[^ ]*\?token=[A-Za-z0-9._-]+' "$WEB_LOG_FILE" 2>/dev/null | tail -n1 || true)"
  if [ -z "$url" ]; then
    url="$(grep -Eo 'http://[0-9A-Za-z.:_-]+[^ ]*' "$WEB_LOG_FILE" 2>/dev/null | tail -n1 || true)"
  fi
  [ -n "$url" ] || die "日志中未找到访问地址（可 dshctl --logs 查看）。"
  printf '  本机访问   : %s\n' "$url"
  if [ -f "$WEB_LAN_PATCH" ]; then
    local ip lan_url
    for ip in $(hostname -I 2>/dev/null || true); do
      case "$ip" in 127.*|*:*) continue ;; esac
      lan_url="$(printf '%s' "$url" | sed -E "s#//[^/:]+(:[0-9]+)?#//$ip\1#")"
      printf '  局域网访问 : %s\n' "$lan_url"
    done
    warn "提示：设置/模型/凭据/插件配置页面仅在 loopback（localhost）访问时可用；"
    warn "      局域网浏览器可聊天、看插件列表，但改配置需本机访问或 SSH 隧道。"
  fi
  info "请使用带 token 的完整地址打开（token 是访问凭证，请勿外泄）。"
  return 0
}

backup_globs() {
  printf '%s\n' \
    "$HOME/dshctl-backup-*.tar.gz" \
    "$HOME/dshctl-preupgrade-*.tar.gz" \
    "$DSH_DIR/.env.bak.*" \
    "$DSH_HOME_ABS/.env.bak.*"
}

do_backups_list() {
  step "备份清单"
  local g files n total=0
  while IFS= read -r g; do
    files="$(ls -1t $g 2>/dev/null || true)"
    [ -n "$files" ] || continue
    n="$(printf '%s\n' "$files" | grep -c . || true)"
    total=$((total + n))
    printf '  %s（%s 份）\n' "$g" "$n"
    printf '%s\n' "$files" | sed 's/^/    /'
  done < <(backup_globs)
  if [ "$total" -eq 0 ]; then
    info "没有任何备份。"
  else
    info "共 $total 份；清理旧备份: dshctl --backups-prune [N]（默认每类保留 3）"
  fi
  return 0
}

do_backups_prune() {
  local keep="${BACKUP_KEEP:-3}"
  step "清理旧备份（每类保留最近 $keep 份）"
  local g files f
  local -a to_delete=()
  while IFS= read -r g; do
    files="$(ls -1t $g 2>/dev/null || true)"
    [ -n "$files" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      to_delete+=("$f")
    done < <(printf '%s\n' "$files" | tail -n +$((keep + 1)))
  done < <(backup_globs)
  if [ "${#to_delete[@]}" -eq 0 ]; then
    info "没有超出保留数量的备份。"
    return 0
  fi
  for f in ${to_delete[@]+"${to_delete[@]}"}; do
    printf '  删除: %s\n' "$f"
  done
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上为预览，未删除任何文件。"
    return 0
  fi
  if ! confirm_config_change "确认删除上述 ${#to_delete[@]} 个旧备份？"; then
    die "已取消。"
  fi
  local deleted=0
  for f in ${to_delete[@]+"${to_delete[@]}"}; do
    if rm -f -- "$f" 2>/dev/null; then deleted=$((deleted + 1)); fi
  done
  ok "已删除 $deleted 个旧备份。"
  return 0
}

model_effective_base() { # 输出: 来源|值（真实优先级: settings.yaml > 启动环境变量 > 协议默认；.env 为非法位置）
  local v=""
  v="$(read_settings_llm_value "$DSH_HOME_ABS/settings.yaml" baseURL)"
  if [ -n "$v" ]; then printf '设置文件|%s' "$v"; return 0; fi
  if [ -n "${DEEPSEEK_BASE_URL:-}" ]; then printf '环境变量|%s' "$DEEPSEEK_BASE_URL"; return 0; fi
  printf '默认|'
  return 0
}

do_model_set_base() {
  local url="$MODEL_BASE_URL"
  case "$url" in
    http://*|https://*) ;;
    *) die "--model-set-base 需要 http(s):// 开头的地址: $url" ;;
  esac
  case "$url" in *'#'*) die "地址包含 # 字符，暂不支持。" ;; esac
  [ -d "$DSH_DIR" ] || die "源码目录不存在: ${DSH_DIR}（请先 --install）"

  local eff src cur
  eff="$(model_effective_base)"
  src="${eff%%|*}"; cur="${eff#*|}"
  printf '  当前地址   : %s（来源: %s）\n' "${cur:-未配置}" "$src"
  printf '  目标地址   : %s\n' "$url"
  printf '  写入位置   : %s/settings.yaml（llm-deepseek.baseURL；dsh 热读取，无需重启）\n' "$DSH_HOME_DISPLAY"
  if [ "$src" = "环境变量" ]; then
    warn "注意: settings.yaml 的显式值优先级高于环境变量；如需取消环境变量请从 shell 配置移除。"
  fi
  local illegal=""
  illegal="$(model_illegal_env_bases)"
  if [ -n "$illegal" ]; then
    warn "检测到 .env 中的非法 Base URL（0.1.6+ 会导致 dsh 拒绝启动），将一并注释并备份："
    local il
    while IFS= read -r il; do
      [ -n "$il" ] && warn "  · ${il%%|*} -> ${il##*|}"
    done <<< "$illegal"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 以上为预览，未做任何改动。"
    return 0
  fi
  if ! confirm_config_change "确认写入 settings.yaml（并清理 .env 非法项）？"; then
    die "已取消。"
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local settings_file="$DSH_HOME_ABS/settings.yaml"
  if [ -f "$settings_file" ]; then
    cp -a -- "$settings_file" "$settings_file.bak.$ts" || die "备份失败: $settings_file"
    info "已备份: $settings_file.bak.$ts"
  fi
  settings_write_baseurl "$url" || die "写入 settings.yaml 失败。"
  ok "已写入 settings.yaml: llm-deepseek.baseURL=$url"

  local f v
  for f in "$DSH_DIR/.env" "$DSH_HOME_ABS/.env"; do
    [ -f "$f" ] || continue
    v="$(env_baseurl_values "$f" | tail -n1 || true)"
    [ -n "$v" ] || continue
    cp -a -- "$f" "$f.bak.$ts" 2>/dev/null || true
    if env_comment_baseurl "$f"; then
      ok "已注释 .env 非法项: ${f}（原值: ${v}）"
    else
      warn "注释失败，请手动处理: $f"
    fi
  done

  local old_bak
  while IFS= read -r old_bak; do
    rm -f -- "$old_bak" 2>/dev/null || true
  done < <(ls -1t "$settings_file".bak.* 2>/dev/null | tail -n +4)
  while IFS= read -r old_bak; do
    rm -f -- "$old_bak" 2>/dev/null || true
  done < <(ls -1t "$DSH_DIR/.env".bak.* "$DSH_HOME_ABS/.env".bak.* 2>/dev/null | tail -n +4)

  info "settings.yaml 变更会被 dsh 热读取（下一次请求生效）；验证: dshctl --model-check"
  return 0
}

do_dry_run() {
  step "[dry-run] 安装计划预览（不做任何改动）"
  if [ "$DO_ROLLBACK" -eq 1 ]; then
    local rb_target="${ROLLBACK_REF:-}"
    if [ -z "$rb_target" ]; then
      rb_target="$(rollback_prev_target)"
    fi
    printf '  回退模式   : 将回退到 %s 并强制重建\n' "${rb_target:-（未找到历史版本，实际执行时会报错）}"
  fi
  local action="克隆"
  [ -d "$DSH_DIR/.git" ] && action="原地更新"
  printf '  源码目录   : %s（%s，ref=%s）\n' "$DSH_DIR" "$action" "$DSH_REF"

  if node_ok; then
    printf '  Node.js    : 已满足（%s）\n' "$(node_ver)"
  else
    printf '  Node.js    : 将自动安装 v%s（nvm 优先，官方包兜底）\n' "$DSH_NODE_MAJOR"
  fi
  printf '  pnpm       : 将准备 pnpm@%s（corepack）\n' "$(repo_pnpm_version)"

  if [ -d "$DSH_DIR/.git" ]; then
    REPO_HEAD="$(repo_head)"
    if [ "$DO_INSTALL_DEPS" -eq 0 ] && [ "$DO_BUILD" -eq 0 ]; then
      printf '  依赖/构建  : 按参数跳过（--skip-deps --no-build）\n'
    elif [ "$FORCE_REBUILD" -eq 0 ] && build_is_current; then
      printf '  依赖/构建  : 源码未变化，将跳过（--rebuild 可强制）\n'
    else
      printf '  依赖/构建  : 将运行 pnpm install%s\n' "$([ "$DO_BUILD" -eq 1 ] && echo " + pnpm run build" || echo "")"
    fi
  else
    printf '  依赖/构建  : 将运行 pnpm install%s\n' "$([ "$DO_BUILD" -eq 1 ] && echo " + pnpm run build" || echo "")"
  fi

  if [ -n "$DSH_API_KEY" ]; then
    printf '  .env       : 将写入（含新 API Key）\n'
  elif [ -f "$DSH_DIR/.env" ]; then
    printf '  .env       : 已存在，将保留\n'
  else
    printf '  .env       : 将生成（不含 API Key，之后可在 Web UI 填写）\n'
  fi

  if [ "$DO_WEB_LAN" -eq 1 ]; then
    printf '  局域网访问 : 将启用（写入补丁%s）\n' "$([ "$DO_LAUNCHER" -eq 1 ] && echo "并由启动器引用" || echo "；未装启动器需手动 --patch")"
  else
    printf '  局域网访问 : 仅本机（如需开启加 --web-lan）\n'
  fi
  printf '  启动器     : %s\n' "$([ "$DO_LAUNCHER" -eq 1 ] && echo "将安装到 $HOME/.local/bin/dsh" || echo "跳过（--no-launcher）")"
  printf '  systemd    : %s\n' "$([ "$DO_SYSTEMD" -eq 1 ] && echo "将安装并启动 dsh.service" || echo "跳过（未指定 --systemd）")"

  if [ -n "$DSH_GIT_PROXY" ]; then
    local scope_disp="$DSH_PROXY_SCOPE"
    if [ "$PROXY_EXPLICIT" -eq 0 ] && [ "$PROXY_SCOPE_EXPLICIT" -eq 0 ]; then
      scope_disp="仅本次运行（不写 git 配置）"
    fi
    printf '  代理       : %s（%s）\n' "$(mask_proxy "$DSH_GIT_PROXY")" "$scope_disp"
  else
    printf '  代理       : 未配置（不可达时将自动探测本地代理）\n'
  fi
  printf '  镜像       : %s\n' "$([ -n "$DSH_NPM_MIRROR$DSH_NODE_MIRROR" ] && echo "npm=${DSH_NPM_MIRROR:-默认} node=${DSH_NODE_MIRROR:-默认}" || echo '自动探测（官方不可达时切换国内镜像）')"

  info "dry-run 结束：以上为预览，未做任何改动。"
}

summary() {
  local head="未知"
  [ -d "$DSH_DIR/.git" ] && head="$(git -C "$DSH_DIR" rev-parse --short HEAD 2>/dev/null || echo 未知)"
  local web_scope="仅本机（127.0.0.1）"
  local direct_cmd="pnpm dsh web"
  if [ "$DO_WEB_LAN" -eq 1 ]; then
    direct_cmd="pnpm dsh web --patch \"$WEB_LAN_PATCH\""
    if [ "$DO_LAUNCHER" -eq 1 ]; then
      web_scope="已启用局域网访问：其他设备访问 http://<本机IP>:${DSH_PORT}（设置/模型等页面仅本机可用）"
    else
      web_scope="补丁已写入；本次未更新启动器，手动启动请加 --patch"
    fi
  fi

  step "安装完成"
  if [ "${UPDATE_FAILED:-0}" -eq 1 ]; then
    printf '  源码更新   : %s⚠ 失败（本地修改阻塞，仍为旧版本；--force-update 可强制覆盖）%s\n' "$C_YELLOW" "$C_RESET"
  fi
  cat <<EOF
  源码目录 : $DSH_DIR   (HEAD: $head)
  Node.js  : $(node -v 2>/dev/null || echo '未就绪')
  pnpm     : $(pnpm --version 2>/dev/null || echo '未就绪')
  日志文件 : $LOG_FILE

启动方式:
  1) 启动器   : dsh web
  2) 直接运行 : cd "$DSH_DIR" && $direct_cmd
  3) 临时体验 : npx @deepseek-ai/dsh web

Web UI 地址: http://127.0.0.1:$DSH_PORT
访问范围 : $web_scope
首次使用步骤:
  · 打开上述地址
  · 设置 → 模型，填入 DeepSeek API Key 并保存（立即生效，无需重启）
  · 点击“选择工作区”，添加并选中一个项目目录
  · 选中工作区后，会话输入框即可使用

常用命令:
  · 无头一次性任务 : pnpm dsh --profile headless "总结这个仓库"
  · 更新源码       : git -C "$DSH_DIR" pull && cd "$DSH_DIR" && pnpm install && pnpm run build
  · 服务状态       : systemctl --user status dsh   (若已安装 --systemd)
EOF

  printf '\n%s注意：DeepSeek Harness 处于开发者预览阶段，版本间可能存在破坏性变更。%s\n' \
    "$C_YELLOW" "$C_RESET"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
  if [ "$DO_VERSION" -eq 1 ]; then
    show_version
    return 0
  fi
  banner
  log "日志将写入: $LOG_FILE"
  log "系统: ${OS}/${ARCH}  发行版: ${DISTRO}"

  validate_args
  resolve_effective_port

  # 只读 / 运维模式：不获取安装锁，不触发安装流程
  if [ "$DO_STATUS" -eq 1 ]; then
    do_status
    return 0
  fi
  if [ "$DO_DOCTOR" -eq 1 ]; then
    do_doctor
    return $?
  fi
  if [ -n "$SERVICE_ACTION" ]; then
    do_service_action
    return 0
  fi
  if [ -n "$PLUGIN_ACTION" ]; then
    case "$PLUGIN_ACTION" in
      add|remove|update|repair|policy-set|policy-reset) acquire_lock ;;
    esac
    do_plugin_action
    return 0
  fi
  if [ -n "$MODEL_ACTION" ]; then
    if [ "$MODEL_ACTION" = "fix" ] || [ "$MODEL_ACTION" = "set-base" ]; then acquire_lock; fi
    case "$MODEL_ACTION" in
      show)     do_model_show ;;
      check)    do_model_check ;;
      fix)      do_model_fix ;;
      set-base) do_model_set_base ;;
    esac
    return 0
  fi
  if [ -n "$DATA_ACTION" ]; then
    case "$DATA_ACTION" in
      backup|restore|archive-sessions|prune) acquire_lock ;;
    esac
    case "$DATA_ACTION" in
      backup)           do_data_backup ;;
      restore)          do_data_restore ;;
      archive-sessions) do_data_archive_sessions ;;
      prune)            do_data_prune ;;
    esac
    return 0
  fi
  if [ -n "$BACKUP_ACTION" ]; then
    if [ "$BACKUP_ACTION" = "prune" ]; then acquire_lock; fi
    case "$BACKUP_ACTION" in
      list)  do_backups_list ;;
      prune) do_backups_prune ;;
    esac
    return 0
  fi
  if [ "$DO_URL" -eq 1 ]; then
    do_url
    return 0
  fi
  if [ "$DO_UPGRADE_CHECK" -eq 1 ]; then
    do_upgrade_check
    return 0
  fi
  if [ "$DO_REGISTER" -eq 1 ]; then
    do_register
    return 0
  fi
  if [ "$DO_UNREGISTER" -eq 1 ]; then
    do_unregister
    return 0
  fi

  if [ "$DO_UNINSTALL" -eq 1 ]; then
    acquire_lock
    do_uninstall
    return 0
  fi

  # 安装/更新必须显式指定 --install；不带参数时只显示帮助
  if [ "$DO_INSTALL" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    if [ "$HAS_ARGS" -eq 0 ]; then
      usage
      return 0
    fi
    warn "未指定操作：安装/更新请用 --install（其他操作见下方帮助）"
    usage
    QUIET_EXIT=1
    return 1
  fi

  # 监听地址校验：上游 CLI 参数仅支持 127.0.0.1；0.0.0.0 由 --web-lan 的 patch 方式实现
  if [ "$DSH_HOST" = "0.0.0.0" ]; then
    if [ "$DO_WEB_LAN" -ne 1 ]; then
      die "参数冲突：--host 0.0.0.0 与 --no-web-lan 同时指定。"
    fi
    info "--host 0.0.0.0 将以局域网访问补丁方式实现（上游 CLI 参数本身禁用 0.0.0.0）。"
    DSH_HOST="127.0.0.1"
  fi
  if [ "$DSH_HOST" = "::" ] || [ "$DSH_HOST" = "[::]" ]; then
    die "上游 dsh 不支持该监听地址（${DSH_HOST}）；局域网访问请用 --web-lan。"
  fi
  if [ "$DSH_HOST" != "127.0.0.1" ]; then
    die "上游仅支持 --host 127.0.0.1；局域网访问请用 --web-lan（绑定 0.0.0.0）。"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    do_dry_run
    return 0
  fi

  if [ "$DO_ROLLBACK" -eq 1 ]; then
    do_rollback_prepare
  fi

  choose_web_lan

  require_cmd git
  require_cmd curl
  acquire_lock

  # git 版本检查（>= 2.26）
  local git_ver major minor
  git_ver="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ -z "$git_ver" ]; then
    warn "无法解析 git 版本号，跳过版本检查。"
  else
    major="${git_ver%%.*}"; minor="${git_ver##*.}"
    if [ "${major:-0}" -lt 2 ] || { [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -lt 26 ]; }; then
      warn "检测到 git ${git_ver}，官方开发指南要求 2.26 及以上（可能影响 Git 集成特性）。"
    else
      ok "git $git_ver 满足要求"
    fi
  fi

  apply_proxy
  apply_mirrors

  ensure_node
  ensure_repo
  preupgrade_backup_if_needed

  local pm_ver
  pm_ver="$(repo_pnpm_version)"
  info "仓库锁定的 pnpm 版本: $pm_ver"
  ensure_pnpm "$pm_ver"

  install_deps
  do_typecheck
  do_build
  write_env
  install_web_lan_patch
  install_launcher
  install_systemd
  headless_selfcheck

  record_install_state
  model_compat_check_warn

  summary
}

main "$@"
