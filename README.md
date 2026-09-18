# dshctl

> DeepSeek Harness（dsh）安装 · 运维 · 清理 一体化脚本

[![CI](https://github.com/thzxx/dshctl/actions/workflows/ci.yml/badge.svg)](https://github.com/thzxx/dshctl/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thzxx/dshctl?display_name=tag)](https://github.com/thzxx/dshctl/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-blue)](#环境要求)

`dshctl.sh` 是一个零依赖的单文件 Bash 脚本：从官方源码安装
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，并覆盖之后的日常运维——
状态体检、服务控制、插件管理、模型配置排障、数据备份、版本回退与彻底卸载。

```bash
# 一条命令完成安装（源码 + 依赖 + 构建 + 启动器）
bash dshctl.sh --install -y --api-key sk-xxxx
# 之后
dshctl --status / --doctor / --restart / --logs
```

> [!IMPORTANT]
> 本项目是社区维护的**非官方**工具，与 DeepSeek 官方无关联。
> dsh 本体处于开发者预览阶段，版本间可能存在破坏性变更；
> 相关上游问题请提交到 [deepseek-harness issues](https://github.com/deepseek-ai/deepseek-harness/issues)。

## 为什么需要 dshctl

从源码运行 dsh 需要一连串容易出错的步骤：Node.js 版本匹配、Corepack/pnpm 激活、
克隆与更新源码、安装依赖、构建、写 `.env`、管理服务进程。国内网络下还要处理 GitHub / npm 的连通性。

dshctl 把这些收敛为一条命令，并且刻意做成**可反复执行**的：
源码未变化时跳过重复 install/build，升级前自动备份运行数据，失败时打印日志定位行号。

## 特性

- **一条命令安装**：环境检查 → Node.js（nvm 优先，官方二进制兜底）→ pnpm（Corepack）→
  克隆源码 → 安装依赖（含 lefthook 自愈）→ 构建 → 写 `.env` → 安装 `dsh` 启动器。
- **网络友好**：代理自动探测（7890/7891/7897/1080 等）、GitHub 镜像、npm/Node 镜像自动回退；
  未显式指定代理时不会偷偷写入 git 配置。
- **增量与安全**：源码未变化自动跳过 install/build；升级前自动备份 `~/.dsh`；
  所有破坏性操作需确认，均支持 `--dry-run` 预览。
- **运维闭环**：`--status` / `--doctor` / `--start|--stop|--restart|--logs`，可选 `systemd --user` 常驻。
- **插件管理**：profile 级增删改查，pnpm 11 供应链策略（`minimumReleaseAge`）的审计、等待时间预估与锁文件重建。
- **模型排障**：针对 dsh 0.1.6+ 的 Messages 协议变化，检查/修复非法的 `DEEPSEEK_BASE_URL` 配置。
- **数据维护**：备份、恢复、旧会话归档、可重建缓存清理，全部带自动备份。
- **版本管理**：升级检查、一键回退到上一次成功安装的版本、备份清单与保留策略。
- **可脚本化**：`-y` 全自动模式，非交互环境行为明确；退出码与日志（`~/.dshctl.log`）可被 CI/运维系统消费。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Linux、macOS、WSL（x86_64 / arm64） |
| Shell | Bash 3.2+（macOS 自带版本可用） |
| 必备命令 | `bash` `git`（≥2.26）`curl` `tar` |
| Node.js | 22.19+ 或 24+；不满足时脚本会自动安装 |
| 磁盘 | 建议 ≥5 GB 可用（源码 + node_modules + 构建产物） |

可选命令：`xz`（解压 Node 包）、`flock`（并发锁，缺失时用目录锁兜底）、
`ss`/`lsof`/`fuser`（识别端口占用）、`systemctl`（systemd --user 服务）。

## 快速开始

### 安装

```bash
# 方式一：克隆仓库（推荐，便于后续更新脚本）
git clone https://github.com/thzxx/dshctl.git
cd dshctl
bash dshctl.sh --install -y --api-key sk-xxxx

# 方式二：只下载脚本
curl -fsSL -o dshctl.sh https://raw.githubusercontent.com/thzxx/dshctl/main/dshctl.sh
bash dshctl.sh --install -y --api-key sk-xxxx
```

安装完成后注册全局命令，之后可以直接使用 `dshctl`：

```bash
bash dshctl.sh --register
dshctl --status
```

### 首次使用

1. 打开启动器输出的地址：`http://127.0.0.1:3080`（带 token 的完整地址可用 `dshctl --url` 查看）；
2. 「设置 → 模型」填入 DeepSeek API Key 并保存（热生效，无需重启）；
3. 点击「选择工作区」，添加并选中一个项目目录；
4. 在会话输入框开始对话。

### 更新与卸载

```bash
bash dshctl.sh --install          # 更新到上游最新（自动跳过无变化的构建）
bash dshctl.sh --upgrade-check    # 只检查上游是否有新版本
bash dshctl.sh --rollback         # 回退到上一次成功安装的版本
bash dshctl.sh --uninstall        # 部分卸载（保留源码与运行数据）
bash dshctl.sh --purge -y         # 完全卸载（自动备份 ~/.dsh 后清理）
```

## 命令速查

| 类别 | 命令 | 说明 |
| --- | --- | --- |
| 安装 | `--install` | 安装 / 更新（`--dir` `--ref` `--shallow` `--clean` `--force-update`） |
| 状态 | `--status` `--doctor` | 安装/服务/端口状态；环境与网络体检（只读） |
| 服务 | `--start` `--stop` `--restart` `--logs` | 前台/后台服务控制，`--logs --last N` 看最近日志 |
| 插件 | `--plugin-list` / `--plugin-add` / `--plugin-remove` / `--plugin-update` | profile 级插件管理（默认 `web`，可 `--profile`） |
| 插件策略 | `--plugin-repair` `--plugin-policy` `--plugin-policy-set N` `--plugin-policy-reset` | pnpm `minimumReleaseAge` 拦截排障 |
| 模型 | `--model-show` `--model-check` `--model-fix` `--model-set-base URL` | 0.1.6+ Base URL 规范检查与修复 |
| 数据 | `--data-backup` `--data-restore FILE` `--data-archive-sessions` `--data-prune` | 备份 / 恢复 / 旧会话归档 / 缓存清理 |
| 版本 | `--rollback [REF]` `--upgrade-check` | 回退与升级检查 |
| 访问 | `--url` `--web-lan` `--trusted-host HOST` | 打印带 token 的地址；局域网访问 |
| 备份管理 | `--backups-list` `--backups-prune [N]` | 列出 / 清理 dshctl 产生的备份 |
| 网络 | `--git-proxy URL` `--github-mirror URL` `--npm-mirror URL` `--node-mirror URL` `--no-proxy` `--no-mirror` | 代理与镜像控制 |
| 卸载 | `--uninstall` `--purge` `--register` `--unregister` | 部分/完全卸载；全局命令注册 |
| 通用 | `-y` `--dry-run` `--log FILE` `-V` `-h` | 非交互、预览、日志与帮助 |

完整选项以 `bash dshctl.sh --help` 为准；场景化用法见 [docs/usage.md](docs/usage.md)。

## 环境变量

所有配置项均可通过环境变量提供（命令行参数优先）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DSH_REPO_URL` | 官方 GitHub 仓库 | 源码仓库地址 |
| `DSH_REF` | `master` | 分支 / tag / commit |
| `DSH_DIR` | `~/deepseek-harness` | 源码目录 |
| `DSH_NODE_MAJOR` | `24` | 自动安装的 Node.js 主版本 |
| `DSH_PNPM_FALLBACK` | `11.7.0` | 无法从仓库读取 pnpm 版本时的兜底 |
| `DSH_HOME` | `~/.dsh` | dsh 运行数据目录 |
| `DSH_PORT` / `DSH_HOST` | `3080` / `127.0.0.1` | Web UI 监听 |
| `DSH_API_KEY` / `DSH_BASE_URL` | 空 | 写入 `.env` / `settings.yaml` |
| `DSH_GIT_PROXY` / `GIT_PROXY` | 空 | HTTP 代理（也读取 `https_proxy`） |
| `DSH_GITHUB_MIRROR` | 空 | GitHub 镜像加速 |
| `DSH_NPM_MIRROR` / `DSH_NODE_MIRROR` | 空 | 留空则自动探测 |
| `DSH_LOG_FILE` / `DSH_LOG_MAX_MB` | `~/.dshctl.log` / `5` | 日志与轮转阈值 |

## 文件与目录

| 路径 | 内容 |
| --- | --- |
| `~/deepseek-harness` | dsh 源码与构建产物（`--dir` 可改） |
| `~/.local/bin/dsh` | dsh 启动器（由 dshctl 生成） |
| `~/.local/bin/dshctl` | 全局命令软链（`--register` 后） |
| `~/.dsh` | dsh 运行数据：会话 / 凭据 / 设置 / 插件 profile |
| `~/.local/state/dsh` | 服务状态：`web.pid` `web.log` `port` 安装版本记录 |
| `~/.dshctl.log` | dshctl 操作日志（轮转保留 `.1`） |
| `~/.local/share/dsh/web-lan.patch.yml` | 局域网访问补丁（`--web-lan` 时生成） |
| `~/.config/systemd/user/dsh.service` | systemd --user 单元（`--systemd` 时生成） |

## 安全说明

- **局域网访问**：`--web-lan` 会把可执行命令的 Web UI（无登录鉴权）暴露给同网段设备，仅限可信网络；
  且 dsh 的「设置 / 模型 / 凭据 / 插件配置」页面按设计只在本机（loopback）访问时可用。
- **密钥与凭据**：`.env` 写入后权限为 `600`；备份文件同样为 `600`；脚本不会向任何第三方上报数据。
- **插件即代码**：安装插件等于引入可执行代码（`--plugin-add` 会显式警告），请确认来源可信。
- **危险操作防护**：删除路径有系统级防护（拒绝 `/`、`$HOME`、顶层目录），卸载/恢复/归档均需确认。

安全问题请按 [SECURITY.md](SECURITY.md) 的流程私下报告。

## 常见问题

- 安装失败 / GitHub 或 npm 不可达 → [docs/troubleshooting.md](docs/troubleshooting.md)
- 升级后旧会话发不出消息 → `dshctl --data-archive-sessions`
- dsh 启动报 `.env` 中的 `DEEPSEEK_BASE_URL` 非法 → `dshctl --model-fix`
- 插件安装被 pnpm 供应链策略拦截 → `dshctl --plugin-policy` / `--plugin-repair`
- 端口被占用（WSL 镜像网络下可能是主机/其他发行版）→ `dshctl --doctor` 或 `--port`

## 开发与贡献

欢迎提交 Issue 与 PR，参与前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。本地检查：

```bash
make check     # bash -n + shellcheck（--severity=warning）+ 测试套件
make test      # 仅运行 tests/
```

项目结构与代码地图见 [docs/development.md](docs/development.md)。

## 许可证与致谢

本项目基于 [MIT 许可证](LICENSE) 开源。
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 为 DeepSeek 官方项目（MIT）；
dshctl 与官方无关联，仅是社区维护的安装与运维工具。
