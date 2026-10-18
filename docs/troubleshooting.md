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

### 构建失败（MISSING_EXPORT / 更新后产物不一致）

症状：`pnpm run build` 报 `[MISSING_EXPORT] ... is not exported by ...`，或类似
`Build failed with`。常见原因是**更新源码后残留了旧的构建产物**（各包 `lib/` 目录），
也可能撞上上游 master 的过渡期提交。

```bash
bash dshctl.sh --install --clean-build                   # 清理构建产物后重建（推荐）
bash dshctl.sh --install --force-update --clean-build    # 若更新曾被本地修改阻塞
bash dshctl.sh --install --clean                         # 彻底重克隆（最彻底）
bash dshctl.sh --upgrade-check                           # 查看上游最新 tag
bash dshctl.sh --install --ref <tag>                     # 锁定到具体版本
```

手工等价操作：在源码目录执行 `pnpm install && pnpm run clean && pnpm run build`。

## 运行 / 模型

### dsh 启动时报 `.env` 中的 `DEEPSEEK_BASE_URL` 非法

dsh 0.1.6+ 拒绝从 `.env` 读取 Base URL。修复：

```bash
bash dshctl.sh --model-fix      # 注释 .env 中的非法行（自动备份）
bash dshctl.sh --model-set-base https://api.deepseek.com/anthropic
```

### 模型地址写到哪里（0.1.7+ 配置迁移）

dsh 0.1.7 起设置从 `~/.dsh/settings.yaml` 迁移到
`~/.dsh/profiles/<profile>/cordis.patch.yml`；旧文件会在首次启动时被自动导入并改名
`settings.yaml.imported`（内容保留）。用 `dshctl --model-show` 可看到实际来源与优先级
（home 配置 > profile 配置 > 启动环境变量）。`protocol` 字段在 0.1.7+ 已不支持，
`dshctl --model-fix` 可自动移除。

### 模型自检失败（404 / 401 / 超时）

```bash
bash dshctl.sh --model-show     # 查看 key 来源与 Base URL 优先级，检查是否指向旧官方根地址
bash dshctl.sh --model-check    # headless 发一条最小消息
```

- 404：Base URL 覆盖指向了旧根地址，Messages 端点应为 `https://api.deepseek.com/anthropic`；
- 401/403：密钥无效或来源不正确（优先级：环境变量 > 凭据文件 > 项目 `.env` > `~/.dsh/.env`）；
- 超时：检查网络/代理，或稍后重试。

### 升级后旧会话发不出消息

dsh 0.2.0 起会按需自动迁移会话格式（v4），旧会话一般可直接打开；若仍异常，可做软重置
（数据保留，可手动移回）：

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

### 插件与 dsh 版本不兼容（0.2.0+）

表现为 `installation rejected: ... is incompatible with dsh ...`（dsh 0.2.1-alpha.4 起插件
声明的 `engines.dsh` 优先，未声明时回退 `peerDependencies`），安装会被回滚；
已安装但未豁免的插件会在启动时被拒载（`--doctor` 可检测）。

```bash
bash dshctl.sh --plugin-exemptions            # 查看当前豁免
bash dshctl.sh --plugin-allow pkg@1.2.3      # 确认风险后授予（会用当前 dsh 版本）
bash dshctl.sh --plugin-revoke pkg@1.2.3     # 撤销
```

优先选择安装与该 dsh 版本兼容的插件版本；豁免是精确到「包@版本 + dsh 版本」的，
授予后可能崩溃或损坏数据。它与 `minimumReleaseAge` 是不同机制。

### 卸载插件提示包名不存在

`--plugin-remove` 需要完整包名（与 `--plugin-list` 显示一致）。

## 访问 / 安全

### Web 启动报「不允许通配地址」（dsh 0.2.1+）

dsh 0.2.1-alpha.2 起 webserver 拒绝 `0.0.0.0`/`::` 等通配地址（例如
`webserver: host "0.0.0.0" is an unspecified (wildcard) address`），必须绑定一个具体网卡地址。
dshctl 已按版本适配：重跑 `--install`（`--web-lan` 会自动绑定本机主网卡 IP），
或显式 `--host <本机IP>`。若此前写过旧版 `web-lan.patch.yml`，重跑安装会自动移除。

### 局域网/远程访问的 host 被拒（403）

GUI 的 `/api` 会校验 Host/Origin。绑定网卡 IP 本身被自动接受；通过自定义域名或反向代理
访问时，需用 `--trusted-host <域名>` 声明（`--public-url` 只是展示，不授予信任）。

### 反向代理访问报「dsh web authentication required」

这是**没带 token** 的默认回应，不是故障：dsh 只认启动输出里那条带 `?token=` 的完整地址，
token 无法用反代参数关掉。

```bash
bash dshctl.sh --url        # 打印带 token 的完整访问地址
```

若**带上 token 仍然**失败，按顺序查：

1. 反代是否把 `Host` 改写成了后端地址（必须原样保留浏览器可见 Host）——
   后果是每次访问都要求重新认证，且 `/api` 返回 403；
2. 反代是否剥掉了挂载前缀（`--public-url https://host/ui/` 时，`/ui/api/...`
   必须以 `/api/...` 抵达后端）；
3. 是否用 `--trusted-host` 点名了浏览器实际使用的 authority。

完整要求、nginx 模板与验证清单见 [reverse-proxy.md](reverse-proxy.md)。

### 浏览器控制台报 CSP 错误（字体 / eval 被拦）

`Refused to load the font 'data:font/...'`、`EvalError: ... 'unsafe-eval' is not an allowed source`
都来自**反代自己添加的 `Content-Security-Policy` 响应头**：dsh 不下发 CSP，其前端需要
`font-src 'self' data:` 与 `'unsafe-eval'`。移除该响应头，或按
[reverse-proxy.md](reverse-proxy.md#4-如果确实要保留-csp) 的最小可用 CSP 调整。

### 原生 HTTPS 启动失败

`--tls-cert`/`--tls-key` 必须成对且为可读的 PEM（证书链 + 未加密私钥），
路径在安装时已转为绝对路径；启动不会回退到 HTTP。用 `dshctl --doctor` 检查证书可读性。

### 忘记访问 token

```bash
bash dshctl.sh --url
```

反向代理场景同理：把 `--url` 输出的完整地址（含 `?token=`）作为**首次访问**的地址，
token 换成会话 cookie 之后，后续用裸域名访问即可。

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
