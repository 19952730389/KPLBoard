# .github

| 文件 | 用途 |
| --- | --- |
| `pull_request_template.md` | PR 模板（勾选改动落在哪个端 + 构建产物自查） |
| `ISSUE_TEMPLATE/bug_report.yml` | Bug 报告表单（端 / 版本 / 系统 / 复现步骤） |
| `repo-check.workflow.yml` | 仓库卫生检查的 GitHub Actions 工作流（**未启用**） |

## 关于 `repo-check.workflow.yml`

这个工作流会检查：构建产物 / 签名材料有没有被误提交、JSON 与 plist 格式是否合法、
Xcode 工程的 `pbxproj` 引用的 Swift 文件是否都还在。本地可以直接跑同样的命令，见文件内各 step。

它现在**没有放在 `.github/workflows/` 下**，因为本机推送用的令牌只有 `repo` 权限，
GitHub 拒绝创建或更新 workflow 文件（`refusing to allow an OAuth App to create or update workflow ...
without workflow scope`）。

启用方式（任选其一）：

1. 在 GitHub 网页上新建 `.github/workflows/repo-check.yml`，把本文件内容粘贴进去；
2. 或者用带 `workflow` scope 的令牌执行：
   ```bash
   git mv .github/repo-check.workflow.yml .github/workflows/repo-check.yml
   git commit -m "ci: 启用仓库卫生检查"
   git push
   ```
