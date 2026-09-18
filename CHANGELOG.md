# 更新日志

本项目遵循[语义化版本](https://semver.org/lang/zh-CN/)，
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

> 说明：1.4.0 是本项目首个以开源仓库形式发布的版本，更早的内部迭代历史不再追溯。

## [Unreleased]

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

[Unreleased]: https://github.com/thzxx/dshctl/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/thzxx/dshctl/releases/tag/v1.4.0
