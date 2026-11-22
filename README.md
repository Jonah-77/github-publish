# github-publish

一个把「碰 GitHub 的动作」收进固定通道的 skill：先分类、再门禁、最后推送并校验，避免「一条 `git push` 直接跑」把脱敏、远端比对、推送后核对整段跳过。

## 它解决什么

直接用 `gh` / `git push` 处理仓库，常见的坑是：把本机私路径和真实邮箱推上公开仓库、远端已经领先还硬推、推送命令没报错但不确定到底上没上去。这个 skill 把动作拆成六类，每一类只有一条路径。

## 六类路由

| 类别 | 场景 | 入口 |
|---|---|---|
| R 只读核查 | 看 CI、看 Pages、比对远端 HEAD、判断推没推上去 | `scripts/check.ps1` |
| A 首次建仓 | 远端还没有这个仓库 | 手工步骤（带确认） |
| B 增量同步 | 仓库已存在、本地有改动 | `scripts/publish.ps1` |
| C 发布面变更 | 开 Pages、改 topics、发 Release、改可见性 | 手工步骤，一次只改一项 |
| D 分支与 PR | 非 main 的改动、需要评审 | 建分支 / 推分支 / 建 PR |
| E 排障 | 推送被拒、404、作者名不对、凭据失效 | 症状表 |

写类操作（A / B / C / D）统一走四道门禁，顺序不能反：**身份 → 脱敏 → 痕迹 → 远端**。

## 目录

```
SKILL.md                 # 完整流程：路由表、门禁、各类命令、排障表、硬规矩
scripts/check.ps1        # 只读核查，不写盘不推送
scripts/publish.ps1      # 增量同步：门禁 → fetch 比对 → add/commit/push → ls-remote 校验
scripts/scan-traces.ps1  # 署名痕迹扫描，只出候选不自动改
```

## 关键设计

- **不自动升级**：说「同步」就只同步，开 Pages / 发 Release / 改可见性必须来自当次要求。
- **不许硬推**：写之前先 `fetch`，`behind` 或 `diverged` 先处理再看，`--force` 不碰 main。
- **推送后必须核对**：`ls-remote` 或 `gh repo view`，不只信「命令没报错」。
- **幂等**：工作树干净且与远端一致时输出 `nothing-to-push`，不伪造提交。
- **机器可读输出**：固定四行 `STATUS / CLASS / SHA / REMOTE`，便于被其他工具调用。

## 前置条件

Windows + PowerShell 5.1 / 7 均可；已安装 [GitHub CLI](https://cli.github.com/) 并 `gh auth login`（scopes 需含 `repo`）；git 提交身份建议用 `noreply` 邮箱。

脚本内的 `gh` / `git` 路径按本机实际情况调整（见 SKILL.md §十二）。

## 安装

把整个目录放进你的 skill 目录即可，例如 `~/.agent-skills/github-publish`，需要时以链接方式共享给多个客户端。

## 许可

MIT
