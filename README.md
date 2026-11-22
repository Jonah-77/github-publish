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
SKILL.md                   # 完整流程：路由表、门禁、各类命令、排障表、硬规矩
platforms.json             # 平台清单：哪个平台该装哪些文件（打包与安装器共用）
LICENSE
scripts/check.ps1          # Windows：只读核查，不写盘不推送
scripts/publish.ps1        # Windows：门禁 → fetch 比对 → add/commit/push → ls-remote 校验
scripts/scan-traces.ps1    # Windows：署名痕迹扫描，只出候选不自动改
scripts/check.sh           # Termux / Linux / macOS：同 check.ps1
scripts/publish.sh         # Termux / Linux / macOS：同 publish.ps1
scripts/scan-traces.sh     # Termux / Linux / macOS：同 scan-traces.ps1
scripts/setup.sh           # 装缺的工具，并把"装了什么"记成清单
scripts/teardown.sh        # 按清单只删自己装的那部分
install/install.ps1        # Windows 安装器：只复制 Windows 那份
install/install.sh         # Termux / Linux / macOS 安装器：只复制 POSIX 那份
.github/workflows/package.yml   # 按平台打两个 zip，用户只下自己那个
```

## 平台与选择性安装

| 平台 | 运行时 | 入口脚本 | setup / teardown |
|---|---|---|---|
| Windows | PowerShell 5.1 / 7.x | `check.ps1` / `publish.ps1` / `scan-traces.ps1` | 手工装 gh（winget），卸 = 删目录 |
| Android（Termux） | bash 4+ | `check.sh` / `publish.sh` / `scan-traces.sh` | `setup.sh` / `teardown.sh` |
| Linux / macOS | bash 4+ | 同上 | 同上 |

**只装自己平台的代码**，两条路都行：

1. **下载 release 里的压缩包**（推荐，手机用这个）：`github-publish-windows.zip` 里只有 `.ps1`，`github-publish-posix.zip` 里只有 `.sh`，另一平台的代码根本不在包里。
2. **从源码装**：跑对应平台的安装器，它只复制本平台文件，其余一律不带：

```powershell
.\install\install.ps1 -DryRun      # Windows，先看要复制哪些
.\install\install.ps1
```

```bash
./install/install.sh --dry-run     # Termux / Linux / macOS
./install/install.sh
```

安装器会写一个 `.platform` 标记；`install.* -Uninstall` 只在标记对得上时才删目录，避免误删你放在同一路径下的其他东西。

这里没有"编译"这一步：全部是文本脚本，装 = 复制，卸 = 删除 + `teardown`。

## 关键设计

- **不自动升级**：说「同步」就只同步，开 Pages / 发 Release / 改可见性必须来自当次要求。
- **不许硬推**：写之前先 `fetch`，`behind` 或 `diverged` 先处理再看，`--force` 不碰 main。
- **推送后必须核对**：`ls-remote` 或 `gh repo view`，不只信「命令没报错」。
- **幂等**：工作树干净且与远端一致时输出 `nothing-to-push`，不伪造提交。
- **机器可读输出**：固定四行 `STATUS / CLASS / SHA / REMOTE`，便于被其他工具调用。

## 前置条件

- Windows 需 PowerShell 5.1 / 7；Android（Termux）/ Linux / macOS 需 bash 4+
- [GitHub CLI](https://cli.github.com/) 已安装并 `gh auth login`（scopes 需含 `repo`）；Termux 用 `pkg install gh`
- git 提交身份建议用 `noreply` 邮箱
- `.ps1` 的 gh / git 路径按本机实际情况调整（见 SKILL.md §十二）；`.sh` 用参数或 `GIT_BIN` / `GH_BIN` 覆盖

## 安装与卸载（组件跟着账本走）

```bash
./scripts/setup.sh --dry-run     # 先看它会做什么
./scripts/setup.sh               # 缺什么装什么（Termux: pkg install gh git）
./scripts/setup.sh --minimal     # 只装 git，推送用 token，不装 gh
```

`setup.sh` 除了装工具，还会把"装了什么"写进 `$HOME/.github-publish/state.tsv`：包名、创建的文件、改过的 git 配置键，并区分"本次装的"和"原本就有"。

以后要卸载：

```bash
~/github-publish-uninstall.sh                  # 只出计划，什么都不改
~/github-publish-uninstall.sh --yes            # 只删清单里"本次装的"
~/github-publish-uninstall.sh --yes --purge-auth   # 连 gh 登录态一起清
```

三点保证：

1. **原本就有的工具一律不碰**（清单里标 `preexisting`）
2. **清单在 skill 目录之外**，先删了 skill 文件夹也还能清理
3. 卸载脚本在 `setup.sh` 时被复制到 `$HOME`，和下一条一样能独立运行

包管理器层面做不到"删目录即自动卸载"，所以约定是**先跑卸载脚本，再删 skill 目录**。

## 许可

MIT
