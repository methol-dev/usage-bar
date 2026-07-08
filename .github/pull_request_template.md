<!-- issue 驱动 PR 由 scripts/issues/ship.sh 创建,body 由 AI 填;手动 PR 亦遵循此模板 -->

## 关联 issue
Closes #<issue-number>

## 修改摘要
- (做了什么 + 为什么;根因分析在 issue comment 里)

## 验证
- (验证命令与结果,按 `.agent/rules/build-test.md` 验证矩阵勾选相关项)
- [ ] CI 绿

## 需人介入自检
- [ ] 未触碰需人介入清单(`.agent/rules/workflows/issue-driven.md`);若触碰 → 已打 `status:needs-human`

## 回滚
- revert 本 PR / 或简述
