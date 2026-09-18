# 变更说明

<!-- 请简要描述本 PR 做了什么、为什么这样做 -->

## 变更类型

- [ ] 修复 Bug（fix）
- [ ] 新功能（feat）
- [ ] 文档（docs）
- [ ] 测试 / CI（test / chore）
- [ ] 破坏性变更（请在描述中显著标注）

## 关联 Issue

<!-- 例如 Closes #12；无关联可写"无" -->

## 验证方式

- [ ] `bash -n dshctl.sh` 通过
- [ ] `shellcheck --severity=warning -x dshctl.sh` 通过
- [ ] `bash tests/run.sh` 通过（或 `make check`）
- [ ] 已补充/更新对应测试
- [ ] 已同步更新 `README.md` / `docs/`（如涉及用户可见行为）

手动验证步骤（如适用）：

<!-- 贴出执行的命令与关键输出 -->

## 兼容性

- [ ] 保持 Bash 3.2（macOS）兼容
- [ ] 未引入新的运行时依赖（dshctl.sh 仍为单文件）
- [ ] 破坏性操作已处理确认交互与 `--dry-run`
