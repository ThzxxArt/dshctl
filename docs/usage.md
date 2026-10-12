# 使用手册

本文按场景说明 dshctl 的常用用法。完整选项列表以 `bash dshctl.sh --help` 为准，
环境变量见 [README 的环境变量一节](../README.md#环境变量)。

## 1. 安装与更新

### 首次安装

```bash
bash dshctl.sh --install -y --api-key sk-xxxx
```

执行流程：环境检查 → Node.js 就绪 → Corepack/pnpm → 克隆官方源码 →
`pnpm install` → `pnpm run build` → 写 `.env` → 安装 `~/.local/bin/dsh` 启动器。
安装结束会输出启动方式、访问地址与首次使用步骤。

### 常用变体

```bash
# 换目录 / 换分支或 tag / 浅克隆（省时间与磁盘）
bash dshctl.sh --install --dir /opt/dsh --ref v0.1.2-alpha.1 --shallow

# 只装依赖不构建；或在构建前做类型检查
bash dshctl.sh --install --no-build
bash dshctl.sh --install --typecheck

# 强制重装依赖并重建（忽略"源码未变化"的智能跳过）
bash dshctl.sh --install --rebuild

# 更新后构建失败（如 MISSING_EXPORT，多为残留旧构建产物 lib/）：
# 先运行 pnpm run clean 清理产物再重建（隐含 --rebuild）
bash dshctl.sh --install --clean-build
# 若更新曾被本地修改阻塞，更新与清理可组合：
bash dshctl.sh --install --force-update --clean-build

# 更新时丢弃本地源码修改（未跟踪文件保留）
bash dshctl.sh --install --force-update

# 重新克隆（目录被污染或想彻底重来时）
bash dshctl.sh --install --clean
```

重复执行 `--install` 是安全的：源码未变化且构建产物存在时，会自动跳过
`pnpm install` 与 `pnpm run build`。每次源码版本变化前，运行数据（`~/.dsh`）会自动备份到
`~/dshctl-preupgrade-<时间戳>.tar.gz`（保留最近 3 份，`--no-backup` 可关闭）。

### 无头自检

```bash
bash dshctl.sh --install --headless-selfcheck   # 构建后发一条最小消息验证链路
```

## 2. 状态与服务

```bash
bash dshctl.sh --status          # 安装位置/版本/构建状态/服务模式/端口/插件/模型兼容性
bash dshctl.sh --doctor          # 环境与网络体检，给出修复建议（发现问题时退出码为 1）
bash dshctl.sh --start           # 启动 Web 服务（systemd 已装则走 systemd）
bash dshctl.sh --restart
bash dshctl.sh --stop
bash dshctl.sh --logs            # 跟踪日志（Ctrl+C 退出）
bash dshctl.sh --logs --last 100 # 只看最近 100 行
```

`--start` 在无 systemd 时使用后台进程模式，PID 与日志写在 `~/.local/state/dsh/`。
未显式指定 `--port` 时，服务控制会使用安装时记录的端口。

## 3. 访问 Web UI

```bash
bash dshctl.sh --url             # 从服务日志中提取带 token 的完整访问地址
```

也可以直接打开 `http://127.0.0.1:3080`（默认端口），或在 Web UI
「设置 → 模型」中完成密钥配置（热生效，无需重启）。

### 局域网访问

```bash
bash dshctl.sh --install --web-lan --port 4000
# 已安装过：重跑安装以写入启动器补丁
```

> [!WARNING]
> 局域网内任何设备都可以访问该 Web UI（无登录鉴权），且它可以执行命令。
> 仅限可信网络使用。

dsh 的「设置 / 模型 / 凭据 / 插件配置」页面按设计只在本机（loopback）访问时可用，
局域网浏览器会提示 `settings are unavailable`。推荐用 SSH 隧道把远端端口映射到本地：

```bash
ssh -N -L 3080:127.0.0.1:3080 user@server
# 然后在本地浏览器访问 http://127.0.0.1:3080
```

`--trusted-host HOST` 可重复使用，把额外的主机名/地址加入 GUI 的信任列表。

## 4. 插件管理

插件按 profile 管理（默认 `web`），变更后需重启服务生效（交互询问，`-y` 自动重启）：

```bash
bash dshctl.sh --plugin-list
bash dshctl.sh --plugin-add github:dsh-external/dsh-session-search#main
bash dshctl.sh --plugin-add @deepseek-ai/dsh-subagent-codex link:../my-plugin
bash dshctl.sh --plugin-remove dsh-session-search
bash dshctl.sh --plugin-update                    # 不带名字 = 更新全部
bash dshctl.sh --plugin-why dsh-session-search    # 依赖来源溯源
bash dshctl.sh --profile work --plugin-list       # 指定其他 profile
```

支持的规格格式：npm 包名、`github:owner/repo#ref`、`link:路径`（本地路径会自动转为绝对路径）。

### 供应链策略（minimumReleaseAge）

pnpm 11 默认拒绝安装「发布未满 24 小时」的依赖，表现为
`ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION`。dshctl 提供：

```bash
bash dshctl.sh --plugin-policy           # 审计当前策略值 + 违规包 + 预计自动通过时间
bash dshctl.sh --plugin-repair           # 重建 profile 锁文件（clean --lockfile + install）
bash dshctl.sh --plugin-policy-set 0     # 关闭策略（0 分钟；谨慎使用）
bash dshctl.sh --plugin-policy-reset     # 恢复 pnpm 默认（1440 分钟）
```

策略配置写在 `~/.dsh/profiles/<profile>/pnpm-workspace.yaml`。

### 插件兼容性门禁（dsh 0.2.0+）

dsh 0.2.0 起会按插件的 `peerDependencies` 校验 dsh 版本：不兼容的安装会被拒绝并回滚，
已安装但未豁免的插件会被启动拒载。dshctl 提供对应的豁免管理：

```bash
bash dshctl.sh --plugin-exemptions                  # 查看当前精确版本豁免（JSON）
bash dshctl.sh --plugin-allow pkg@1.2.3             # 授予豁免（使用已装 dsh 版本；需确认风险）
bash dshctl.sh --plugin-revoke pkg@1.2.3            # 撤销豁免
```

豁免是「精确包名@版本 + 精确 dsh 版本」级别的，记录在
`~/.dsh/profiles/<profile>/compatibility.json`。授予豁免意味着接受崩溃或数据损坏风险，
更推荐先尝试安装与该 dsh 版本兼容的插件版本。这与 `minimumReleaseAge`（发布年龄冷静期）
是两个不同的机制。

## 5. 模型配置维护

dsh 0.1.6 起默认使用 Messages 协议，且**不允许**把 `DEEPSEEK_BASE_URL` 写在 `.env`
（会导致拒绝启动）。Base URL 的合法位置随版本变化：

- **dsh 0.1.7+**：profile 配置 `~/.dsh/profiles/<profile>/cordis.patch.yml` 中
  `llm-deepseek` 条目的 `config.baseURL`；
- **≤0.1.6**：`~/.dsh/settings.yaml` 的 `llm-deepseek.baseURL`（升级到 0.1.7+ 时会被自动
  导入 profile 并改名为 `settings.yaml.imported`）。

```bash
bash dshctl.sh --model-show                            # key 脱敏、来源标注、合规性检查
bash dshctl.sh --model-check                           # headless 发一条最小消息验证连通
bash dshctl.sh --model-fix                             # 注释 .env 非法项；移除 0.1.7+ 的 protocol 字段
bash dshctl.sh --model-set-base https://api.deepseek.com/anthropic
bash dshctl.sh --profile work --model-show             # 指定其他 profile
```

官方 Messages 端点为 `https://api.deepseek.com/anthropic`；第三方网关请填写其
Anthropic 兼容地址。`settings.yaml` 会被 dsh 热读取；profile 配置由 dsh 热加载，未生效时
可 `dshctl --restart`。另外，`protocol` 字段在 0.1.7+ 已不再支持、0.2.0 会拒绝启动，
`--model-fix` 可自动移除。

## 6. 数据维护

运行数据位于 `~/.dsh`（会话、凭据、设置、插件 profile）：

```bash
bash dshctl.sh --data-backup              # 备份到 ~/dshctl-backup-<时间戳>.tar.gz（权限 600）
bash dshctl.sh --data-restore FILE        # 恢复（先停服务、自动备份现状、完成后询问重启）
bash dshctl.sh --data-archive-sessions    # 旧会话不兼容时软重置：sessions → sessions-archive-<时间戳>
bash dshctl.sh --data-prune               # 清理可重建的图片请求缓存等
```

升级前后建议先 `--data-backup`。恢复不会删除归档数据，只覆盖当前 `~/.dsh`。
dsh 0.1.7+ 会自动迁移旧 `settings.yaml`，0.2.0 起会话格式也会自动升级（旧会话按需保留
后继），因此 `--data-archive-sessions` 通常只用于需要彻底软重置的场景。

## 7. 版本管理与回退

```bash
bash dshctl.sh --upgrade-check    # 对比上游最新 tag / master（只读）
bash dshctl.sh --rollback         # 回退到上一次成功安装的版本并重新构建
bash dshctl.sh --rollback v0.1.2-alpha.1
```

回退只改变源码版本，**不会**回滚 `~/.dsh` 运行数据；新版本写入的数据可能与旧版本不兼容。
尤其注意：0.1.7+ 已把设置迁移为 profile 配置、0.2.0 会话为 v4 格式，回退后旧版本可能
无法使用，执行前请先 `--data-backup`。安装历史记录保存在
`~/.local/state/dsh/installed.history`（最近 5 条）。

## 8. 备份管理

```bash
bash dshctl.sh --backups-list       # 列出 purge/升级前/.env 备份
bash dshctl.sh --backups-prune      # 每类保留最近 3 份，删除更早的
bash dshctl.sh --backups-prune 5    # 自定义保留数量
```

## 9. 卸载

```bash
bash dshctl.sh --uninstall              # 停止服务、移除启动器；保留源码与运行数据
bash dshctl.sh --uninstall --clean      # 额外删除源码目录
bash dshctl.sh --purge -y               # 完全卸载：源码 + ~/.dsh + 日志 + git 代理配置
                                        # （删除前自动备份运行数据，--no-backup 可跳过）
```

`--purge` 不会删除共享运行时（nvm、`~/.local/node`），如需清理会打印手动命令。

## 10. 全局命令与脚本化

```bash
bash dshctl.sh --register     # 注册 ~/.local/bin/dshctl 软链，之后可直接 dshctl ...
bash dshctl.sh --unregister
```

无人值守环境（CI、远程脚本）中的约定：

- `-y`：使用默认值并跳过确认；非交互环境下需要确认的操作（`--purge`、修改配置等）
  必须显式给 `-y`，否则会报错退出而不是卡住等待输入；
- `--dry-run`：预览安装/卸载/插件/数据/备份等操作，不做任何改动；
- `--log FILE` 与 `--log-max-mb N`：控制日志落盘位置与轮转；
- 退出码非 0 时，日志尾部会打印失败原因与所在行号（见 `~/.dshctl.log`）。
