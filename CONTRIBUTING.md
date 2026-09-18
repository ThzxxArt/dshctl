# 贡献指南

感谢参与 dshctl！本文档说明开发环境、代码规范与提交流程。

参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 环境准备

- Bash 3.2+（macOS 自带版本即可，脚本需要保持兼容）
- `git`、`curl`、`tar`
- [ShellCheck](https://github.com/koalaman/shellcheck) ≥ 0.10
  - Ubuntu/Debian：`sudo apt-get install shellcheck`
  - macOS：`brew install shellcheck`

## 本地检查

提交前请确保以下命令全部通过（CI 会执行同样的检查）：

```bash
bash -n dshctl.sh                          # 语法
shellcheck --severity=warning -x dshctl.sh # 静态检查
bash tests/run.sh                          # 测试套件
# 或者一条命令：
make check
```

测试套件在隔离的临时 `HOME` 中运行，不会触碰你的真实环境；新增功能时请补充对应测试。

## 代码规范

- **面向用户的所有输出使用中文**，风格与现有文案一致（`info` / `ok` / `warn` / `err` / `die`）。
- **缩进 2 空格**；保持文件现有排版风格，不强制使用格式化工具（本项目未采用 shfmt 全量重排）。
- **错误处理**：可预期的失败用 `die "原因与建议"`；不要用裸 `exit 1`。
- **幂等性**：所有操作必须可重复执行；重复执行不产生副作用。
- **安全性**：
  - 删除文件/目录必须经过 `reject_dangerous_path` / `safe_rm_rf`；
  - 修改用户配置前先备份（`cp -a` 到 `.bak.<时间戳>`）；
  - 新增交互必须支持 `-y` 非交互路径，并明确 `DRY_RUN` 行为；
  - 不得新增任何向第三方上报数据的行为。
- **兼容性**：Bash 3.2（macOS）与 GNU/BSD 命令差异；外部命令缺失时要有兜底或明确报错。
  两个必须遵守的 Bash 3.2 陷阱（CI 的 macOS 任务会验证）：
  - `$var` 后紧跟多字节字符（中文等）必须写成 `${var}`，否则变量名会被吞字节；
  - 空数组展开必须写成 `${arr[@]+"${arr[@]}"}`，直接 `"${arr[@]}"` 在 `set -u` 下会报错。
- **无新增运行时依赖**：dshctl.sh 必须保持单文件、零依赖。

## 新增一个操作

在 `dshctl.sh` 中新增命令时，请按以下检查清单同步修改：

1. `usage()`：添加选项说明与示例；
2. 参数解析循环：设置对应的全局状态变量；
3. `validate_args()`：加入操作互斥与「选项-模式」校验；
4. `main()`：在只读分支（不取锁）或写操作分支（`acquire_lock`）中分发；
5. 输出与退出码：失败给出可操作的修复建议，退出码与语义一致；
6. 文档：更新 `README.md` 命令表与 `docs/usage.md`（必要时 `docs/troubleshooting.md`）；
7. 测试：在 `tests/` 中补充 CLI 契约测试（`--help` 文案、校验失败、dry-run 等）。

## 提交与 PR

- 提交信息建议使用 [Conventional Commits](https://www.conventionalcommits.org/) 风格：
  `feat(plugin): ...`、`fix(proxy): ...`、`docs: ...`、`test: ...`、`chore(ci): ...`。
- 一个 PR 只做一件事；破坏性变更请在描述中显著标注。
- PR 描述请包含：变更动机、行为变化、验证方式（贴出 `make check` 结果或手动验证步骤）。
- 不要提交 `.env`、日志、备份等本地产物（已在 `.gitignore` 中排除）。

## 发布流程（维护者）

1. 更新 `dshctl.sh` 中的 `DSHCTL_VERSION`；
2. 在 `CHANGELOG.md` 中把 `[Unreleased]` 内容整理为新的版本小节（含日期）；
3. 本地 `make check` 全绿后提交；
4. 打 tag 并推送：

   ```bash
   git tag -a v1.4.1 -m "dshctl v1.4.1"
   git push origin v1.4.1
   ```

5. GitHub Actions 的 Release 工作流会校验 tag 与脚本版本一致，自动生成发布说明并附加 `dshctl.sh`。

也可使用 `make release` 完成第 3~4 步中的本地部分（校验工作区、创建 tag）。
