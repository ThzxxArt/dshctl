# 更新日志

本项目遵循[语义化版本](https://semver.org/lang/zh-CN/)，
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

> 说明：1.4.0 是本项目首个以开源仓库形式发布的版本，更早的内部迭代历史不再追溯。

## [Unreleased]

### 新增

- **反向代理接入手册** `docs/reverse-proxy.md`：实测确认三类互不相同的故障源——
  dsh 的启动 token（首次访问必须带 `?token=`，反代参数无法关闭）、dsh 的 Host 栅栏
  （`--trusted-host` 只放行、不认证）、反代自身的 basic auth 与 CSP 响应头
  （会拦下 `/manifest.webmanifest` 等免鉴权静态资源，并拦截前端所需的内联字体与 `eval`）。
  含可直接套用的完整 nginx 模板（basic auth 放行 / WebSocket 升级 / 后端故障页）、
  `add_header` 的追加与继承语义、最小可用 CSP、六条 curl 验证清单与控制台现象对照表。
- 同一手册另补两项反代视角的实测结论：**dsh 自身不设防的路径**——`/plugins/events` 与
  `/plugins/*` 免凭证返回完整插件清单与插件源码（11 条路径逐一实测），故反代认证层往往是
  唯一覆盖它的那一层；**token 与 cookie 的生命周期**——token 每次启动重新生成且会进反代
  访问日志，cookie 默认 30 天、绑定 authority、不带 `Secure`（须以 HSTS 补偿），
  并给出访问日志脱敏写法。
- 排障手册新增「反向代理访问报 dsh web authentication required」「浏览器控制台报 CSP 错误」
  两条；`--url` 条目补充反代场景说明；使用手册对外地址一节补充反代要点。

### 修复

- **README 安全说明的事实错误**：原称 Web UI「无登录鉴权」，实际 dsh 有启动 token 认证门
  （首次访问须用带 `?token=` 的完整地址）。现改为「有 token 认证门，但监听端口本身不受保护」，
  并明确经反代暴露时建议在反代再加一道认证。中英文同步。

## [1.5.1] - 2026-10-17

核对 DeepSeek Harness 0.2.1 候选版（`dsh-v0.2.1-rc.1` / `dsh-v0.2.1-rc.2`）。
结论：脚本依赖的上游接口面（`dsh web` 参数、`dsh plugin` 子命令与豁免命令、profile 目录结构、
兼容门禁、Node/pnpm 版本要求、构建脚本、会话格式）自 `0.2.1-alpha.4` 起**无变化**，
本次无需兼容性改造；`rc.1` 相对 `alpha.5` 仅改动各 `package.json` 的版本号。

### 修复

- **`--upgrade-check` 漏报同 `X.Y.Z` 内的预发布升级**：`version_ge` 原先只比较前三个数字段、
  忽略预发布后缀，会把 `0.2.1-alpha.5` 判成「不低于上游最新 tag」（上游为 `0.2.1-rc.2`）。
  现按 semver 2.0.0 预发布优先级比较：数字段相同后，正式版 > 预发布版；两者都带预发布时
  逐段比较——数字标识符按数值（忽略前导零）、数字标识符 < 非数字标识符、非数字标识符按
  ASCII 顺序（`LC_ALL=C` 固定，不受语言环境影响），公共前缀相同时标识符多者更大。
- **上游 tag 定序统一到同一实现**：`latest_upstream_tag` 原先依赖 `sort -V`，而 GNU 与 BSD
  （macOS）的 `-V` 语义不同——BSD 把预发布后缀当字符串比较，`alpha.10` 会排在 `alpha.9` 之前，
  使 `--upgrade-check` 与构建失败指引在 macOS 上可能锁定过旧的 tag。现改为复用 `version_ge`
  取最大值，版本定序只有一个归属实现。新增 `tests/test_version_compare.sh` 覆盖定序表与
  `--upgrade-check` 结论行（stub git，不触网）。

### 变更

- 「临时体验」提示由 `npx @deepseek-ai/dsh web` 改为 `npx @deepseek-ai/dsh@next web`：
  npm 的 `latest` 标签仍停在 `0.2.0-rc.2`，0.2.1 候选线挂在 `next` 上。
- 首次使用步骤补充账号登录路径：仅本机 HTTP 访问时（dsh 0.2.1+）可在「设置 → 账号」登录
  DeepSeek 账号而无需 API Key；经 `--web-lan` / `--public-url` / `--tls-cert` / `--trusted-host`
  暴露的部署仍须使用 API Key（上游只接受回环 HTTP 作为登录回调 origin）。README（中/英）同步。
- 插件变更后的重启说明放宽：dsh 0.2.1+ 支持依赖同步与热重载，dshctl 仍会重启服务以确保生效。

## [1.5.0] - 2026-10-16

适配 DeepSeek Harness 0.2.1（当前最新 `dsh-v0.2.1-alpha.4`），并新增 Web 对外访问能力。

### 修复（破坏性变更适配）

- **`--web-lan` 重写以适配 dsh 0.2.1**：0.2.1-alpha.2 起上游 webserver 拒绝
  `0.0.0.0` 等通配地址（加载即报错，导致 Web 启动失败）。现在按版本分流：
  0.2.1-alpha.2+ 自动绑定本机主网卡 IPv4（启动时探测，网卡变化自动重试）；
  ≤0.2.1-alpha.1（含 0.2.0）仍沿用 `0.0.0.0` 补丁方式。
- **headless 凭据语义修正**：dsh 0.2.1-alpha.3 起 headless 不再读取 GUI 保存的凭据
  （只读环境变量 / `.env`）。`--model-check` 与 `--headless-selfcheck` 不再把
  `~/.dsh/.credentials.yaml` 当作 headless 可用密钥，必要时临时注入以免自检假阴性。
- **`--port 0` 实际端口探测**：只读取本次启动新写入的日志（避免读到上一次运行的历史 URL），
  并在启动成功后记录实际端口，`--status` / `--url` 随之准确。
- **`--url` / `--doctor` 健壮性**：`--url` 取日志中最新一次启动的地址（不再被历史地址干扰）；
  `--doctor` 的一句「Web UI 可达性」按真实绑定地址与协议（含 HTTPS）探测，并绕过代理。

### 新增

- **`--host HOST`**：绑定一个具体 IPv4/IPv6 网卡地址（dsh 0.2.1+；通配地址仍兼容为局域网请求）。
- **`--public-url URL`**：反向代理对外地址（`http(s)://`，可带路径前缀）。
- **`--tls-cert FILE` / `--tls-key FILE`**：原生 HTTPS 证书链与私钥（须成对；相对路径安装时转绝对）。
- **`--port 0`**：由系统分配空闲端口，启动后从日志读取实际端口。
- 以上选项随 `--install` 写入启动器，也支持 `--start` 临时生效；`--status` / `--url` / `--doctor`
  展示局域网绑定、对外地址、HTTPS 与信任主机。

### 变更

- 插件兼容性说明更新为 0.2.1+ 优先 `engines.dsh`、未声明时回退 `peerDependencies`。
- `DSH_PNPM_FALLBACK` 默认值更新为 `11.28.5`（与上游仓库锁定版本一致）。
- `--web-lan` 不再声称「设置/模型等页面仅 loopback 可用」（0.2.1 已支持非 loopback / 反向代理访问）。

## [1.4.2] - 2026-10-12

### 新增

- `--clean-build`：安装依赖后先运行仓库自带的 `pnpm run clean`（清理 `lib/` 等构建产物）
  再强制重建。用于修复「更新源码后残留旧构建产物」导致的构建失败（隐式 `--rebuild`）。

### 变更

- 构建失败时输出针对性指引：识别 `MISSING_EXPORT` / `Build failed with` 特征，
  依次建议 `--clean-build`、`--force-update --clean-build`、`--clean`，并自动查询最新上游
  tag 供 `--ref` 锁定；其他构建失败也给出清理/重克隆建议。
- `--upgrade-check` 与构建失败指引共用 `latest_upstream_tag` 查询逻辑。

## [1.4.1] - 2026-10-02

适配 DeepSeek Harness 0.1.7+ / 0.2.0（当前最新 `dsh-v0.2.0-rc.2`），保持 ≤0.1.6 兼容。

### 新增

- **插件兼容性门禁支持**（dsh 0.2.0+）：`--plugin-exemptions` 查看 profile 的精确版本
  豁免、`--plugin-allow` 授予豁免（含风险确认，自动使用已装 dsh 版本）、`--plugin-revoke`
  撤销豁免；插件失败提示新增不兼容文案识别与豁免指引，`--doctor` 可检测启动拒载。
- `--profile` 现在可用于模型维护命令（`--model-*`）。

### 变更

- **模型配置适配 dsh 0.1.7+**：设置从 `~/.dsh/settings.yaml` 迁移到
  `~/.dsh/profiles/<profile>/cordis.patch.yml`（`llm-deepseek` 条目的 `config.baseURL`）。
  `--model-set-base` / `--install --base-url` 按版本选择写入位置；
  `--model-show` 读取 profile/home 配置并标注来源与优先级。
- `--model-fix` 支持移除 0.1.7+ 不再支持、0.2.0 会拒绝启动的 `protocol` 字段（自动备份）。
- `--data-archive-sessions` 与 `--rollback` 补充 0.2.0 会话 v4 / 配置迁移说明；
  `--typecheck` 提示 0.2.0+ 会连带构建 desktop bundle。
- `--backups-list` 纳入 `settings.yaml` / `cordis.patch.yml` 的 `.bak` 备份。

### 修复

- `installed_dsh_version` 在 node 不可用时增加纯 shell 兜底，版本检测不再依赖 node 可执行。
- 模型配置展示与实际生效来源一致（home 配置 > profile 配置 > 启动环境变量）。

### 工程

- 新增 `tests/test_model_settings.sh`、`tests/test_plugin_exemptions.sh`，测试套件增至
  8 个文件、165 个断言。

## [1.4.0] - 2026-09-18

### 新增

- **安装 / 更新**：源码克隆与更新（分支 / tag / commit，支持 `--shallow` 浅克隆）、
  Node.js 自动就绪（nvm 优先、官方二进制 tar 包兜底）、Corepack 激活仓库锁定的 pnpm、
  `pnpm install`（含 lefthook 钩子自愈）与 `pnpm run build`、`.env` 生成、
  `dsh` 启动器安装、`systemd --user` 服务、无头模式自检。
- **智能增量**：`--rebuild` 之外的场景在源码未变化时跳过 install/build；
  `--force-update` 丢弃本地修改强制更新。
- **网络适配**：本地代理端口自动探测（7890/7891/7897/1080 等）、git 按 URL 代理与
  `--proxy-scope` 控制、GitHub 镜像、npm/Node 镜像自动回退、`--no-proxy` / `--no-mirror`。
- **运维**：`--status` 状态总览、`--doctor` 环境与网络体检、
  `--start|--stop|--restart|--logs` 服务控制（systemd 与后台进程双模式）。
- **插件管理**：`--plugin-list|add|remove|update|why`（profile 级，本地路径规格自动转绝对路径）。
- **插件供应链策略**：`--plugin-policy` 审计 `minimumReleaseAge`、`--plugin-policy-set|reset`、
  `--plugin-repair` 重建 profile 锁文件，并预估违规包的自动通过时间。
- **模型维护**：`--model-show` 配置总览（脱敏）、`--model-check` 连通性自检、
  `--model-fix` 修复 `.env` 中非法的 `DEEPSEEK_BASE_URL`、`--model-set-base` 写入 `settings.yaml`。
- **数据维护**：`--data-backup|restore|archive-sessions|prune`；升级前自动备份运行数据（保留最近 3 份）。
- **版本管理**：`--rollback [REF]` 回退、`--upgrade-check` 上游对比、安装历史记录（最近 5 条）。
- **访问助手**：`--url` 打印带 token 的地址、`--web-lan` 局域网访问（patch 方式绑定 `0.0.0.0`）、
  `--trusted-host`。
- **备份管理**：`--backups-list`、`--backups-prune [N]`（默认每类保留 3 份）。
- **生命周期**：`--register` / `--unregister` 全局命令、`--uninstall` 部分卸载、
  `--purge` 完全卸载（删除前自动备份数据）。
- **安全与健壮性**：并发锁（flock / 目录锁兜底）、危险路径删除防护、`.env` 权限 600、
  日志轮转、失败行号定位、`--dry-run` 全操作预览。

### 工程化

- 初始化开源仓库：MIT 许可证、中英文 README、场景化使用文档与排障手册、贡献指南、
  行为准则、安全政策、Issue / PR 模板。
- 增加 ShellCheck 静态检查、CLI 测试套件与 GitHub Actions CI；发布工作流在打 tag 时
  自动校验版本一致性并创建 Release。

[Unreleased]: https://github.com/ThzxxArt/dshctl/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/ThzxxArt/dshctl/releases/tag/v1.5.0
[1.4.2]: https://github.com/ThzxxArt/dshctl/releases/tag/v1.4.2
[1.4.1]: https://github.com/ThzxxArt/dshctl/releases/tag/v1.4.1
[1.4.0]: https://github.com/ThzxxArt/dshctl/releases/tag/v1.4.0
