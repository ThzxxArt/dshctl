# 开发指南

本页说明仓库结构、`dshctl.sh` 的代码地图、测试方式与发布流程。
贡献流程与代码规范见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 仓库结构

```
dshctl/
├── dshctl.sh                  # 唯一交付物：单文件、零依赖的 Bash 脚本（约 4200 行）
├── tests/                     # 隔离环境中的 CLI 契约测试（纯 Bash，无外部框架）
│   ├── run.sh                 # 测试入口：依次运行 test_*.sh
│   ├── lib.sh                 # 断言与隔离 HOME 的小型测试库
│   └── test_*.sh              # 按主题分组的测试文件
├── docs/
│   ├── usage.md               # 场景化使用手册
│   ├── troubleshooting.md     # 排障手册（症状 → 原因 → 处理）
│   └── development.md         # 本文件
├── .github/workflows/         # CI（bash -n + shellcheck + 测试矩阵）与 Release
├── Makefile                   # make check / lint / test / release
└── README.md / README.en.md   # 中文主文档与英文简介
```

设计约束：**交付物只有一个文件** `dshctl.sh`。新增功能不得引入运行时依赖或拆分文件，
测试与 CI 全部在仓库侧完成。

## dshctl.sh 代码地图

脚本自上而下分为以下区块（函数名稳定，行号会漂移）：

| 区块 | 关键函数 | 说明 |
| --- | --- | --- |
| 默认配置 | 顶部变量 | 所有配置均可被环境变量覆盖；命令行参数优先级最高 |
| 输出与日志 | `log` `info` `ok` `warn` `err` `die` `step` `prepare_logging` `cleanup` | tee 双写终端与 `~/.dshctl.log`；失败打印行号；EXIT 时等待落盘 |
| 参数解析 | `usage` `need_val` `validate_args` | 操作互斥（`MODE`）、「选项-模式」匹配、取值合法性 |
| 环境探测 | `detect_distro` `require_cmd` `reject_dangerous_path` `safe_rm_rf` `port_listening` `port_listener_pid` `wait_port_free` `check_url` `acquire_lock` | 跨平台（Linux/macOS/WSL）兜底与并发锁 |
| Node.js | `node_ok` `load_nvm` `install_nvm` `install_node_via_nvm` `install_node_via_tarball` `ensure_node` | nvm 优先，官方 tar 包兜底 |
| pnpm | `repo_pnpm_version` `ensure_pnpm` | Corepack 优先，npm 全局安装兜底 |
| 代理与镜像 | `autodetect_proxy` `apply_proxy` `apply_mirrors` `effective_repo_url` | 环境变量代理 vs git 持久化配置的边界 |
| 仓库获取 | `git_exclude_add` `heal_own_gitignore` `build_is_current` `write_build_stamp` `ensure_repo` | 更新、强制覆盖、构建戳（`.dshctl-stamp`） |
| 依赖与构建 | `install_deps` `do_typecheck` `do_build` | lefthook 自愈；智能跳过 |
| 环境文件 | `write_env` | `.env`（权限 600）+ `settings.yaml` Base URL 迁移 |
| 局域网 | `choose_web_lan` `install_web_lan_patch` | 以 patch 覆盖 webserver 配置实现 `0.0.0.0` |
| 集成 | `install_launcher` `install_systemd` `headless_selfcheck` | 启动器 ~65 行；systemd 单元生成 |
| 卸载 | `do_uninstall` | `--purge` 先列清单、再确认、最后删除；自动备份数据 |
| 运维 | `do_status` `do_doctor` `service_mode` `service_ctl_pid` `do_service_action` | systemd 与后台进程双模式 |
| 插件 | `resolve_plugin_spec` `plugin_run` `do_plugin_*` `plugin_failure_hint` | profile 级管理；策略违规等待时间精确计算 |
| 模型 | `mask_secret` `settings_write_baseurl` `model_*` `do_model_*` | 0.1.6+ 协议兼容检查与修复 |
| 数据 | `do_data_backup` `do_data_restore` `do_data_archive_sessions` `do_data_prune` | 破坏性操作全部带确认与现状备份 |
| 版本 | `version_ge` `do_upgrade_check` `rollback_prev_target` `do_rollback_prepare` | 基于 `installed.history` 的历史回退 |
| 访问/备份 | `do_url` `backup_globs` `do_backups_list` `do_backups_prune` | 备份保留策略 |
| 主流程 | `main` | 只读命令不取锁；写命令 `acquire_lock`；安装/更新必须显式 `--install` |

### 关键机制

- **MODE 互斥**：`validate_args` 把所有操作归一到唯一 `MODE`；只读命令（status/doctor/url 等）
  不获取安装锁，写操作通过 `acquire_lock` 串行化。
- **状态文件**：`~/.local/state/dsh/` 保存 `port`、`installed.version`、`installed.head`、
  `installed.history`（最近 5 条）、`web.pid`、`web.log`。
- **构建戳**：`.dshctl-stamp` 记录构建对应的 `HEAD`；`build_is_current` 决定是否跳过 install/build。
  该文件通过 `.git/info/exclude` 忽略，不会污染上游仓库的 `.gitignore`。
- **DRY_RUN**：所有写操作必须先处理 `DRY_RUN=1` 分支（打印预览并返回 0），再进入确认与执行。
- **失败定位**：`ERR` trap 记录 `BASH_LINENO`，`cleanup` 在退出时输出失败行号与日志位置。

## 测试

测试目标是在**不触碰真实系统**的前提下验证 CLI 契约。`tests/lib.sh` 会：

- 为每个测试文件创建独立的临时 `HOME` 与 `DSH_DIR`；
- 清空可能影响结果的 `DSH_*`、代理类环境变量；
- 提供 `run_dshctl` 与断言函数（退出码、stdout/stderr 包含、文件存在性）。

运行：

```bash
bash tests/run.sh          # 或用 make test
```

新增行为时请同步补充测试。适合测试的内容：帮助/版本输出、参数校验与互斥、`--dry-run` 无副作用、
只读命令、注册/注销软链、版本与文档一致性。不适合在测试中执行的：真实安装/构建（需要网络与大量时间）。

## 兼容性约束

- **Bash 3.2**（macOS 自带）：不使用关联数组、`mapfile`、`${var,,}` 等 Bash 4+ 特性；
  另需注意两个 Bash 3.2 陷阱：
  - `$var` 后紧跟多字节字符时必须写 `${var}`（否则变量名会被多字节字节污染）；
  - 空数组展开必须写 `${arr[@]+"${arr[@]}"}`（直接 `"${arr[@]}"` 在 `set -u` 下报 unbound variable）；
- **GNU/BSD 差异**：`date`、`sed -i`、`grep -E` 等均有兜底或 BSD 分支；
- **无 jq**：解析 JSON 使用 `node -e`，且对 node 缺失场景保持降级可用；
- **外部命令缺失**：`xz` `flock` `ss`/`lsof`/`fuser` 均有降级路径。

本地验证 Bash 3.2 兼容性（可选）：自行编译 Bash 3.2 后，用 `DSH_TEST_BASH` 指定二进制运行测试：

```bash
DSH_TEST_BASH=/path/to/bash-3.2/bash PATH="/path/to/bash-3.2:$PATH" bash tests/run.sh
```

## 发布流程

1. 修改 `DSHCTL_VERSION`（`dshctl.sh` 顶部）与 `CHANGELOG.md`；
2. `make check` 全绿；
3. `make release`（校验工作区干净并创建 `v<版本>` 注释 tag）；
4. `git push origin main v<版本>` 触发 Release 工作流：
   校验 tag 与脚本版本一致 → 从 `CHANGELOG.md` 提取发布说明 → 创建 Release 并附加 `dshctl.sh`。
