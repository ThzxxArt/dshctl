# 排障手册

按「症状 → 原因 → 处理」组织。遇到问题时建议先执行：

```bash
bash dshctl.sh --doctor      # 环境与网络体检
bash dshctl.sh --status      # 安装与服务状态
bash dshctl.sh --logs --last 100
```

所有操作的完整日志在 `~/.dshctl.log`（超过 5 MB 自动轮转为 `.1`，`--log-max-mb 0` 关闭轮转）。

## 安装 / 网络

### GitHub 不可达、克隆或下载缓慢

脚本会按以下顺序自救，并打印所用方式：

1. 自动探测本地 HTTP 代理端口（`7890` `7891` `7897` `1080` `8118` `8888`）；
2. 未指定镜像且官方源不可达时，自动切换 npm / Node 镜像（会明确提示）；
3. 仍失败时打印告警并继续。

手动指定更可靠：

```bash
bash dshctl.sh --install --git-proxy http://127.0.0.1:7890
bash dshctl.sh --install --github-mirror https://gitclone.com/github.com/
bash dshctl.sh --install --npm-mirror https://registry.npmmirror.com --node-mirror https://npmmirror.com/mirrors/node
```

注意：dsh 本体不支持 SOCKS 代理（会跳过并直连），`socks5://` 仅对 git/curl/pnpm 生效；
Web UI 与模型调用需要代理时请填写 HTTP 端口。

### 代理被意外写入 git 配置

只有显式传 `--git-proxy`（或设置 `DSH_GIT_PROXY`）且未指定 `--proxy-scope none` 时才会写入。
撤销方式：

```bash
git config --global --unset http.https://github.com/.proxy
```

### git 快进合并失败（本地修改阻塞更新）

```bash
bash dshctl.sh --install --force-update   # 丢弃本地修改更新到目标 ref（未跟踪文件保留）
bash dshctl.sh --install --clean          # 或删除目录重新克隆
```

### Node.js 版本不符

要求 `22.19+` 或 `24+`。脚本会自动安装（nvm 优先，失败则用官方二进制包，落在 `~/.local/node`）。
禁止自动安装时加 `--skip-node-install`，只指定版本可加 `--node-major N`。

### corepack / pnpm 准备失败

`ensure_pnpm` 的兜底顺序：`corepack prepare` → `corepack install -g` → `npm install -g pnpm@<版本>`。
全部失败时按提示手动执行：

```bash
corepack enable && corepack prepare pnpm@<版本> --activate
```

版本以仓库 `package.json` 的 `packageManager` 字段为准，可用 `--pnpm-version` 覆盖兜底值。

### lefthook 钩子告警

`pnpm install` 的 postinstall 会配置 Git 钩子；缓存还原时可能被跳过，脚本会重试一次，
失败仅告警，不影响运行（只影响提交期检查）。

## 运行 / 模型

### dsh 启动时报 `.env` 中的 `DEEPSEEK_BASE_URL` 非法

dsh 0.1.6+ 拒绝从 `.env` 读取 Base URL。修复：

```bash
bash dshctl.sh --model-fix      # 注释 .env 中的非法行（自动备份）
bash dshctl.sh --model-set-base https://api.deepseek.com/anthropic   # 写入 settings.yaml
```

### 模型自检失败（404 / 401 / 超时）

```bash
bash dshctl.sh --model-show     # 查看 key 来源与 Base URL 优先级，检查是否指向旧官方根地址
bash dshctl.sh --model-check    # headless 发一条最小消息
```

- 404：Base URL 覆盖指向了旧根地址，Messages 端点应为 `https://api.deepseek.com/anthropic`；
- 401/403：密钥无效或来源不正确（优先级：环境变量 > 凭据文件 > 项目 `.env` > `~/.dsh/.env`）；
- 超时：检查网络/代理，或稍后重试。

### 升级后旧会话发不出消息

新旧版本会话数据不兼容，软重置（数据保留，可手动移回）：

```bash
bash dshctl.sh --stop
bash dshctl.sh --data-archive-sessions
```

### 端口被占用

```bash
bash dshctl.sh --doctor              # 检查占用者
bash dshctl.sh --stop                # 会尝试终止监听进程并等待端口释放
bash dshctl.sh --start --port 4001   # 或换端口
```

WSL 镜像网络模式下，占用可能出现「无法识别进程」的提示——此时占用者来自其他 WSL 发行版
或 Windows 主机，需要在那侧排查。

### systemd --user 不可用（WSL / 无用户会话总线）

安装会保留单元文件 `~/.config/systemd/user/dsh.service` 但跳过启动；可直接用
`dshctl --start` 以后台进程方式运行。若会话支持 systemd，可手动：

```bash
systemctl --user enable --now dsh
sudo loginctl enable-linger $USER   # 未登录时保持运行
```

## 插件

### 安装被 `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` 拦截

```bash
bash dshctl.sh --plugin-policy        # 查看违规包与预计自动通过时间
bash dshctl.sh --plugin-repair        # 重建 profile 锁文件
# 或信任来源后放宽/关闭策略：
bash dshctl.sh --plugin-policy-set 0
```

### 提示 `allowBuilds` 拦截（插件含构建脚本）

按输出提示把对应的 key 加入 `~/.dsh/profiles/<profile>/pnpm-workspace.yaml` 后重试。

### 卸载插件提示包名不存在

`--plugin-remove` 需要完整包名（与 `--plugin-list` 显示一致）。

## 访问 / 安全

### 局域网访问提示 `settings are unavailable`

这是上游设计：设置/模型/凭据/插件配置页面仅限 loopback。请在本机用 `localhost` 访问，
或使用 SSH 隧道（见 [usage.md 的局域网访问一节](usage.md#局域网访问)）。

### 忘记访问 token

```bash
bash dshctl.sh --url
```

### 如何确认脚本没有做多余的事

- 所有破坏性操作都需要确认（非交互环境需要 `-y`）；
- 先用 `--dry-run` 预览；
- 脚本不收集、不上报任何数据；
- 删除路径有防护（拒绝 `/`、`$HOME`、顶层系统目录）。

## 卸载相关

### 卸载后想彻底清理残留

```bash
bash dshctl.sh --backups-list    # 先看看有哪些备份要保留
bash dshctl.sh --purge -y        # 源码 + ~/.dsh + 日志 + git 代理配置（自动备份数据）
```

共享运行时（`~/.nvm`、`~/.local/node`）不会自动删除，`--purge` 结束时会打印清理命令。
