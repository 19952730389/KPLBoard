# .github

| 文件 | 用途 |
| --- | --- |
| `pull_request_template.md` | PR 模板（勾选改动落在哪个端 + 构建产物自查） |
| `ISSUE_TEMPLATE/bug_report.yml` | Bug 报告表单（端 / 版本 / 系统 / 复现步骤） |
| `repo-check.workflow.yml` | 仓库卫生检查的 GitHub Actions 工作流（**待启用**） |

检查逻辑本身不在这里，而是放在 [`scripts/check-repo.py`](../scripts/check-repo.py)：
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

## 关于 `repo-check.workflow.yml`（待启用）

它现在**没有放在 `.github/workflows/` 下**。原因是本机推送用的令牌只有 `repo` scope，
GitHub 会直接拒绝创建或更新 workflow 文件：

```
refusing to allow an OAuth App to create or update workflow
`.github/workflows/xxx.yml` without `workflow` scope
```

### 启用方式 A：网页上新建（最快，不需要给任何令牌）

1. 打开 <https://github.com/19952730389/KPLBoard/new/main/.github/workflows>
2. 文件名填 `repo-check.yml`
3. 把本目录下 `repo-check.workflow.yml` 的内容整段粘贴进去
4. Commit 到 `main`，之后每次 push / PR 都会自动跑

网页走的是登录态，不受令牌 scope 限制。

### 启用方式 B：给一个带 `workflow` scope 的令牌

到 <https://github.com/settings/tokens/new> 生成 **Personal access token (classic)**，勾选：

- `repo` —— 推送代码
- `workflow` —— 写 `.github/workflows/` 下的文件
- `delete_repo` —— 顺手清理测试用的空仓库（可选）

把令牌给我，我用它把文件挪到 `.github/workflows/repo-check.yml` 再推一次。
