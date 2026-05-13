# 验证记录

## 命令 / 步骤

```bash
cd macos && swift build -c release   # 构建
swift test                           # 全套单测
```

## 结果 / 截图

- `swift build -c release`：Build complete! (预存 warnings 均为 pre-existing，无新增)
- `swift test`：Executed 269 tests, with 0 failures (0 unexpected)

### 新增测试

| 测试名 | 验证内容 | 结果 |
|---|---|---|
| `testBootstrapDoesNotSaveRefreshToken` | `strippingRefreshToken()` helper 正确去除 RT | ✅ passed |
| `testMigrationStripsRefreshTokenMatchingKeychain` | 迁移剥离与 Keychain RT 一致的存储 RT | ✅ passed |
| `testMigrationDoesNotAffectDifferentRefreshToken` | PKCE 账号（RT 不同）迁移不受影响 | ✅ passed |
| `testKeychainRecoveryDoesNotSaveRefreshToken` | Keychain 恢复路径不保存 CLI refresh_token | ✅ passed |

## 本地验证清单

- [x] 单测：`swift test` 全绿，269 个测试 0 失败
- [x] 构建：`swift build -c release` 成功，无新增 error/warning
- [x] 接口契约：`StoredCredentials.strippingRefreshToken()` 是内部 extension，不影响 Codable schema
- [ ] 手动回归：UI 层无变更，无需 Xcode build 回归

## CI

- (PR checks 状态由 ship/merge 阶段记录)
