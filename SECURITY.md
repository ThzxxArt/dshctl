# 安全政策

## 支持的版本

| 版本 | 安全更新 |
| --- | --- |
| 1.4.x | ✅ |
| < 1.4 | ❌ |

## 报告漏洞

请**不要**通过公开 Issue 报告安全漏洞。请使用 GitHub 的私密漏洞报告：

👉 <https://github.com/ThzxxArt/dshctl/security/advisories/new>

报告请尽量包含：

- dshctl 版本（`dshctl --version`）；
- 操作系统与发行版（Linux / macOS / WSL，含版本号）；
- 漏洞类型与影响（例如：任意文件删除、命令注入、权限提升、敏感信息泄露）；
- 最小复现步骤或 PoC；
- 相关日志（`~/.dshctl.log`，提交前请先脱敏）。

我们会在 72 小时内确认收到，并在修复发布后于 Security Advisory 中致谢（如你愿意）。

## 范围

**属于本项目范围**：

- `dshctl.sh` 及本仓库内的脚本、测试与工作流；
- 由 dshctl 生成的文件（启动器、systemd 单元、局域网补丁、备份文件）导致的权限或隐私问题。

**不属于本项目范围**：

- DeepSeek Harness（dsh）本体及其依赖的漏洞，请报告到
  <https://github.com/deepseek-ai/deepseek-harness/security>；
- 社会工程、物理访问、以及攻击者已获得本机用户权限后的攻击场景。

## 安全设计

- dshctl 不收集、不上报任何遥测数据；
- API Key 仅写入用户本机 `.env`（权限 `600`），或由用户在 Web UI 中填写；
- 备份文件权限 `600`；
- 删除操作有危险路径防护（拒绝 `/`、`$HOME`、顶层系统目录）；
- 默认仅本机访问 Web UI；`--web-lan` 需显式开启并给出安全警告；
- 插件安装被视为引入可执行代码，执行前明确警告来源风险。
