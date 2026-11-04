# .github

| 文件 | 用途 |
| --- | --- |
| `workflows/repo-check.yml` | 仓库卫生检查（push / PR / 手动触发） |
| `pull_request_template.md` | PR 模板（勾选改动落在哪个端 + 构建产物自查） |
| `ISSUE_TEMPLATE/bug_report.yml` | Bug 报告表单（端 / 版本 / 系统 / 复现步骤） |

检查逻辑本身在 [`scripts/check-repo.py`](../scripts/check-repo.py)：
本地和 CI 跑同一份代码，不会出现「本地过、CI 挂」的两套规则。

```bash
# 提交前先跑一遍
python3 scripts/check-repo.py
```

它检查四件事：

1. 构建产物 / 本机文件有没有被误提交（`build/`、`*.hap`、`*.ipa`、`DerivedData/`、`xcuserdata/` 等）
2. 签名材料有没有被误提交（`*.p12`、`*.cer`、`*.p7b`、`signing/`）
3. 所有 JSON / plist / entitlements 能否解析
4. Xcode 工程的 `pbxproj` 引用的 Swift 文件是否都还在

## 分支保护建议

`main` 上建议开启要求检查通过的规则（Settings → Branches → Add rule）：

- Require status checks to pass：勾选 `仓库卫生检查`
- 这样构建产物误入库的 PR 会直接被挡在合并之前

CI 只读仓库、不写任何东西（workflow 里 `permissions: contents: read`），不需要额外密钥。
