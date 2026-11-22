---
name: github-publish
description: 只要动作会落在这个 GitHub 账号或它的远端仓库上——推送、拉取、看 CI、开 Pages、建仓、发 Release、改 topics/可见性、开 PR、查远端 HEAD、凭据失效排障——就必须先走本 skill；反过来，纯本地 git 操作、写代码、构建、发布到别的平台都不用它。触发词：推送 github、同步到 github、push、拉一下远端、发布仓库、建 github 仓库、开 Pages、发 Release、看 CI、开 PR、推送失败、脱敏审查、署名痕迹。
---

# GitHub 通道（本机）

**一句话**：凡是要碰 GitHub 的动作都从这里路由。先按「操作类别」定路线，再按该类的最小前置检查与脚本执行；**不许一类命令顺手干另一类的事**。

本目录即 skill 真身。实际使用中常被多个客户端以链接（junction / symlink）指向同一份，改这里各处同时生效。

## 零、什么时候该进来，什么时候别进来

**判据只有一句：这条命令或这个动作，会不会真的碰到 GitHub？** 会就进来，不会就别碰。

**必须进来（否则就是错）**

- 命令里出现 `gh`（任何子命令）；命令里出现 `git push / fetch / pull / clone / ls-remote`，且远端是 `github.com`。
- 用户说了这些意思：推到 GitHub、同步到仓库、开 Pages、建仓库、发版、改仓库设置、查 CI、开 PR、为什么推不上去。
- 要给公开仓库做提交前的脱敏 / 署名痕迹审查。

**不要进来**

- 纯本地 git：`init`、`commit`、`status`、`log`、本地分支与合并，远端不涉及 GitHub。
- 读写本地文件、看某段代码、跑测试、编译、打包。
- 发布到别的平台（网盘、飞书、私有服务器、npm、NuGet）。
- 只是"想知道仓库里有什么"这种纯本地读取。

**最容易犯的错（别重犯）**

> 「这次只是 `git push` 一条命令，很简单，直接跑吧。」

这个念头出现时恰恰是必须进来的时候：门禁（脱敏 / 痕迹）、远端比对、推送后校验都在这里，命令越简单越容易把它们整段跳过。**复杂不复杂不是判据，碰不碰 GitHub 才是。**

## 一、先分类，再动手（唯一入口表）

| 类别 | 归到这一类的情形 | 怎么做 | 一次能做什么 | 需用户确认 |
|---|---|---|---|---|
| **R 只读核查** | 看 CI 结果、看 Pages 是否上线、看远端 HEAD 与本地差多少、看 PR/Release、判断"到底推上去没有" | §三 / `scripts/check.ps1` | 只读，可反复跑 | 不需要 |
| **A 首次建仓与首次发布** | 远端还没有这个仓库、或要把一个本地项目第一次公开 | §四 手工步骤 | 建仓 + 首推（Pages/topics 可并在同一次确认里做） | **必须**：仓库名、公开/私有、一句话描述 |
| **B 增量同步** | 仓库已存在、本地有改动要推 | §五 / `scripts/publish.ps1` | 门禁 → 提交 → 推送 → 校验 | 不需要（变更完成后立即推是既定偏好） |
| **C 发布面变更** | 开/改 Pages 源、改 topics、发 Release、改可见性或协作者 | §六 手工步骤 | **一次只改一项** | **逐项确认** |
| **D 分支与 PR** | 非 main 的改动、需要评审 | §七 | 建分支 / 推分支 / 建 PR | PR 标题正文要先看过 |
| **E 排障** | 推送被拒、404、作者名不对、凭据失效 | §八 症状表 | 按症状处理 | 视动作而定 |

**三条路由纪律**

1. 一次调用只落一类；跨类必须串行且有明确理由（例：B 推完 → 用户说要展示 → 再 C-1 开 Pages）。
2. **不许自动升级**：调用方说"同步"，不许顺手开 Pages、发 Release、改可见性。升级必须来自用户的当次要求。
3. 拿不准就退到 R 只读，把状态摆出来再决定，不要凭猜先写。

## 二、写类操作的四道门禁（A / B / C / D 共用，顺序不能反）

1. **身份门禁**：仓库本地 `user.name` / `user.email` 必须有，邮箱用 noreply（全局为空是常态，不是故障）。
2. **脱敏门禁**：`git add` **之前**扫被跟踪文件。必查：真实姓名与同事姓名、手机号、真实邮箱、`C:\Users\<用户名>` 这类本机绝对路径、公司/客户名、`ghp_` / `github_pat_` 串、`.env`、构建产物（`bin/ obj/ *.user`）。`.gitignore` 要挡住它们，`.gitattributes` 用 `* text=auto eol=lf` 免换行噪音。
3. **痕迹门禁**：`scripts/scan-traces.ps1 -Repo <repo>`，**只出候选、不自动改**，逐条人工判断。判据只有一条——**这段文字是不是只有坐在电脑前的人才会写？** 是就留，不是就改。

   | 类别 | 典型形态 | 处理 |
   |---|---|---|
   | 生成声明 | `Generated with ...`、`Co-Authored-By: Claude`、「部分内容可能由 AI 生成」 | 删，连前面的空行一起删 |
   | 机器视角 | 「面向下一个接手这个库的 **agent**」、「重用**本机 GCM 凭据**」、`this machine` | 改成人话：接手的人、本机环境、本地凭据 |
   | 本机私路径 | `D:\Work\...`、`C:\Users\<me>\...` | 换占位符 |
   | 工具配置 | `CLAUDE.md`、`.claude/`、`.cursorrules`、`AGENTS.md`、`.mcp.json` | 整个不提交，`.gitignore` 挡住 |
   | 露动机的句子 | 「截成图片、再**交给 AI 分析**」 | 是产品定位就留；只是顺手用的，换成真实用途 |

   四条原则：① 先分真假阳性，`Math.Clamp`、`cursor=hand2`、`@deepseek-ai/*` 都不是痕迹；② 产品本身就是 AI 工具的仓库只清文档、不动定位；③ 删文档要成套（引用、目录树、CHANGELOG 一起清，**断链比原文更显眼**），删前本地留备份；④ 只动文字不动代码。

4. **远端门禁**：写之前先 `fetch`，看本地相对远端是 `ahead` / `behind` / `diverged`。`behind` 或 `diverged` 先按 §五 B.2 处理，**不许直接 push 撞上去**。

## 三、R 只读核查

```powershell
& '<skill dir>\scripts\check.ps1' -Repo '<repo 绝对路径>'
```

输出固定四行 `STATUS= / CLASS=R / SHA= / REMOTE=` 加一段明细（auth、本地/远端 SHA、dirty、ahead/behind、最近一次 CI 状态、Pages 构建状态）。手工等价：

```powershell
& 'C:\Program Files\GitHub CLI\gh.exe' auth status
git -C <repo> fetch origin; git -C <repo> status -sb
git -C <repo> ls-remote --heads origin main
& 'C:\Program Files\GitHub CLI\gh.exe' run list --repo <owner>/<repo> --limit 3
& 'C:\Program Files\GitHub CLI\gh.exe' api repos/<owner>/<repo>/pages/builds/latest --jq '.status'
```

## 四、A 首次建仓（一次性，带不可逆动作）

先确认三件事：仓库名、公开还是私有、一句话描述（描述会出现在仓库首页，写成产品口径而不是"练习项目"）。

```powershell
cd <repo>
git init -b main
git config user.name  "<your-name>"
git config user.email "<id>+<account>@users.noreply.github.com"
# 门禁 1-3 全部通过后再继续
& 'C:\Program Files\GitHub CLI\gh.exe' repo create <Name> --public --source . --remote origin --push --description "<一句话>"
```

- `--push` 会直接推第一次，**所以门禁必须在它之前跑完**。
- 首次要不要同时开 Pages / 打 topics，属于 C 类；用户在这次建仓请求里一并说了才做，没说不做。

## 五、B 增量同步

### B.1 标准路径（走脚本，别手拼命令）

```powershell
& '<skill dir>\scripts\publish.ps1' -Repo '<repo>' -Message "<一句话，动词开头>"
# 多行说明写文件，别在命令行拼引号：
& '<skill dir>\scripts\publish.ps1' -Repo '<repo>' -MessageFile "$env:TEMP\msg.txt"
# 先预演：只跑四道门禁与远端比对，列出待提交内容，不暂存、不提交、不推送
& '<skill dir>\scripts\publish.ps1' -Repo '<repo>' -DryRun
# 推完等 CI：只认本次 commit 的 headSha，超时标 pending
& '<skill dir>\scripts\publish.ps1' -Repo '<repo>' -Message "..." -WaitCi
```

脚本内部顺序是固定的：**门禁（身份/脱敏/痕迹）→ fetch 比对 → add → commit → push（网络瞬断自动重试 1 次）→ `ls-remote` 校验 → 输出四行**。它不做建仓，也不碰发布面。

`-DryRun` 不碰 index，所以预演之后工作树与原状一致；`-WaitCi` 默认等 120 秒（`-CiTimeoutSec` 可调），**只有 `headSha` 与本次提交一致的运行才算数**——推送刚发生时 gh 的"最新一次运行"往往还是上一次的结论，不能拿来充数。

### B.2 远端领先或分叉（必须先处理，不能硬推）

```powershell
git -C <repo> fetch origin
git -C <repo> log --oneline origin/main -5      # 看远端多了什么
git -C <repo> rebase origin/main                # 仅 behind：可以自动
# 若出现 modify/delete 冲突（远端删了我这边改的文件）：
git -C <repo> rm --quiet -- '<那个文件>'        # 接受远端删除
git -C <repo> -c core.editor=true rebase --continue
git -C <repo> push origin main
```

判断口径：`behind` 且本地无自有提交 → `git merge --ff-only origin/main` 即可；**`diverged`（双方都有新提交）→ 停，先让人看清两边改了什么再决定**，因为 rebase 会改写本地提交身份。

### B.3 幂等

工作树干净且与远端一致时，脚本输出 `STATUS=nothing-to-push`、退出码 0，**不伪造提交、不改时间戳**。

### B.4 提交说明口径

写"改了什么 + 为什么"，动词开头，一次改动一次提交。**永不写**"清理 AI 痕迹""去除生成声明""update"——那句话本身就是最大的痕迹。

## 六、C 发布面变更（逐项确认，一次一项）

**C-1 开 Pages**

```powershell
$body='{"source":{"branch":"main","path":"/docs"}}'
[IO.File]::WriteAllText("$env:TEMP\pages.json",$body,(New-Object Text.UTF8Encoding($false)))
& 'C:\Program Files\GitHub CLI\gh.exe' api -X POST repos/<owner>/<repo>/pages --input "$env:TEMP\pages.json"
& 'C:\Program Files\GitHub CLI\gh.exe' api repos/<owner>/<repo>/pages/builds/latest --jq '.status'
```

目录里必须有 `index.html`；页面图片用**同目录相对路径**。`building` → `built` 约 30–60 秒，之后抓一次首页 200 + 一张图 200 才算通。

**C-2 topics**：`gh api` 只认 `names` 字段，`topics[]=x` 会 422。

```powershell
$json='{"names":["winforms","miuix","csharp"]}'
[IO.File]::WriteAllText("$env:TEMP\topics.json",$json,(New-Object Text.UTF8Encoding($false)))
& 'C:\Program Files\GitHub CLI\gh.exe' api -X PUT repos/<owner>/<repo>/topics --input "$env:TEMP\topics.json"
```

**C-3 Release**：`gh release create <tag> --generate-notes`；tag 一旦发布就别重打，重打等于换内容。

**C-4 可见性 / 协作者**：`gh repo edit --visibility`。公开→私有会掉 stars 和 watch，属于不可逆的对外影响，必须先把代价讲给用户。

## 七、D 分支与 PR

```powershell
git -C <repo> switch -c <branch>
# 改动后：publish.ps1 只推当前分支，首次推用 -u
git -C <repo> push -u origin <branch>
& 'C:\Program Files\GitHub CLI\gh.exe' pr create --base main --head <branch> --title "<title>" --body "<body>"
```

main 保护开着时，PR 是唯一入口，**不要**为了省事去关保护或直推。

## 八、E 排障

| 症状 | 原因 | 做法 |
|---|---|---|
| `Recv failure: Connection was aborted` / `reset` | 本机网络瞬断 | 直接重跑，别改配置；`publish.ps1` 已内置重试 1 次 |
| `! [rejected] ... non-fast-forward` | 远端领先（别处推过） | 按 §五 B.2，先 fetch 再 rebase，**不要** `--force` |
| 推送要求输入用户名/密码 | GCM 凭据丢了 | `gh auth login` 重新授权（设备码流程见下） |
| 提交作者显示成机器名 | 忘了仓库本地身份 | 未推送前 `git commit --amend --reset-author`；已推送则不追改 |
| `gh: Invalid request. "names" wasn't supplied (422)` | topics 写法错 | 用 `--input` 传 `{"names":[...]}` |
| Pages 404 | 缺 `index.html` 或构建未完成 | 补入口、等 `built` 再验 |
| 页面图片裂 | 图片在 `assets/` 但路径写成同目录 | 路径与文件位置对齐 |
| `.git/rebase-merge` 已存在 | 上次 rebase 中断 | 先 `rebase --continue` 或 `--abort` 收干净，再谈推送 |

**授权（设备码流程）**

```powershell
"y" | & 'C:\Program Files\GitHub CLI\gh.exe' auth login --hostname github.com --git-protocol https --web
```

设备码属登录凭据：**不代填、不抄进回复正文**；把 `https://github.com/login/device` 在用户浏览器里打开，让他自己粘码。旧码 15 分钟失效，页面关了就重跑换新码。

## 九、危险动作（必须拿到明确的"做"）

force push（尤其 main）、改写已推送历史、删仓库、删分支、改可见性、重打已发布 tag、动协作者权限。

统一口径：先把代价说清（不可逆、别人的 clone 失效、外部引用断链），等用户明确同意；**"你没反对"不算同意**。改历史比痕迹本身更显眼，能不重写就不重写。

## 十、被其他工具 / Agent 调用时的契约

调用方可能是别的客户端会话、另一个 Agent，或本机脚本。**双方都按这个形状来**，否则就是"一锅炖"。

**输入（缺一不可）**

| 字段 | 含义 |
|---|---|
| `repoPath` | 仓库绝对路径 |
| `intent` | `r`（只读）/ `sync`（增量）/ `surface`（发布面单项）/ `init`（首次建仓） |
| `message` | `sync` 必填；没给就**拒绝提交**，不许自己编提交说明 |
| `allow` | 调用方已拿到的用户确认范围，如 `["pages"]`；**没列出的发布面动作一律不做** |
| `flags`（可选） | `dryRun`（只要预演结果）、`waitCi`（推完要 CI 结论）——都只作用于 sync，不许借它做别的事 |

**输出（固定四行，便于调用方解析）**

```
STATUS=ok|nothing-to-push|blocked|failed
CLASS=r|sync|init|surface
SHA=<短 SHA 或 ->
REMOTE=in-sync|ahead|behind|diverged|n/a
NOTE=<一句话原因或下一步>
```

**约束（双向）**

1. 不跨类、不自动升级；`intent=sync` 就只做 sync。
2. **不留在中间态**：冲突未解决必须恢复到干净工作树（`rebase --abort` / `merge --abort`）再退出，并在 `NOTE` 写明。
3. 不静默改写历史：rebase 只允许两种情形——本地提交尚未推送，或远端无分叉的 behind。
4. 不打印凭据：token、设备码不进 stdout，也不进回复正文。
5. 三端一致：解释器与工具用绝对路径（node、python 用各安装目录下的可执行文件，git、gh 见 §十二），不依赖某端注入变量。
6. **非 GitHub 的工作不进本 skill**：写代码、本地打包、传到别的平台一律走各自通道。
7. 并发：同一仓库不许两个调用方同时 sync；动手前看 `.git/rebase-merge`、`.git/merge`、`.git/index.lock`，存在即报 `STATUS=blocked`。

## 十一、硬规矩

1. 设备码 / token 不进对话正文，不写进仓库，也不写进任何 `.md`。
2. 提交身份用 noreply 邮箱，不用真实邮箱。
3. 公开仓库**先脱敏再 `git add`**；扫描只看被跟踪文件。
4. 不 `git push --force` 到 `main`；改写已推送历史要用户明确同意。
5. 一次改动一次提交，说明写"改了什么 + 为什么"，不写"update"。
6. 推送后必须核对 `git ls-remote` 或 `gh repo view`，**别只信命令没报错**。
7. 提交说明永不提"清理 AI 痕迹""去除生成声明"。
8. 不为了遮盖去改历史；没有 `Co-Authored-By` 就不用重写。
9. 不伪造署名：不写"纯手写""全部原创"，也不替仓库编假作者故事。
10. 脚本保持纯 ASCII（PS 5.1 与 7 都能跑）；带中文的 `.ps1` 必须 UTF-8 **带 BOM**。
11. 只读与写类分开：`check.ps1` 不写盘、不推、不改仓库状态。

## 十二、本机事实（照抄，别猜）

| 项 | 值 |
|---|---|
| gh CLI | `C:\Program Files\GitHub CLI\gh.exe`（v2.104.0） |
| git | `C:\Program Files\Git\cmd\git.exe` |
| 已登录账号 | `<your-account>`，https 协议，token 存于 keyring，scopes 含 `repo` |
| git 凭据 | 系统级 `credential.helper=manager`（GCM），github.com 凭据已在 Windows 凭据管理器 |
| 提交身份 | 仓库本地配置，全局为空；`<your-name>` / `<id>+<account>@users.noreply.github.com` |
| 网络特征 | 偶发 `Recv failure`，重试一次基本能过 |
| 主力仓库示例 | `<owner>/<repo>`（Pages 源 `main` + `/docs`） |

## 十三、跨平台：手机 / Linux / macOS

Windows 以外的场合（Android 的 Termux、Linux、macOS）没有 PowerShell，用同一套流程的 bash 版，语义与 PowerShell 版一致，输出仍是四行 `STATUS / CLASS / SHA / REMOTE / NOTE`。

| 用途 | Windows | 其它平台 |
|---|---|---|
| 只读核查 | `scripts/check.ps1` | `scripts/check.sh` |
| 增量同步 | `scripts/publish.ps1` | `scripts/publish.sh` |
| 痕迹扫描 | `scripts/scan-traces.ps1` | `scripts/scan-traces.sh` |
| 装/卸工具链 | 手工 | `scripts/setup.sh` / `scripts/teardown.sh` |

bash 版的工具路径按 `--git` / `--gh` → `GIT_BIN` / `GH_BIN` → PATH 的顺序解析，不写死 `C:\Program Files\...`。

### 13.1 手机（Termux）从零到能推

```bash
./scripts/setup.sh            # 缺什么装什么，并记账；先 --dry-run 可只看计划
gh auth login --hostname github.com --git-protocol https --web   # 设备码自己粘，不进对话
./scripts/check.sh --repo <repo>      # 确认 auth / 远端状态
./scripts/publish.sh --repo <repo> --message "<动词开头的一句话>"
```

Termux 里 `pkg install gh` 是官方支持的正规渠道，不需要自己编二进制；git 的 https 凭据通过 `gh auth git-credential` 接管，不依赖 GCM。

### 13.2 组件与 skill 绑定：先记账，再卸载

`setup.sh` 干两件事：缺什么装什么；**把装了什么写进 `$HOME/.github-publish/state.tsv`**。清单记三类——`pkg`（包）、`file`（创建的文件）、`gitconfig`（改过的配置键）——并且只记"本次由我安装"的，事先就存在的标成 `preexisting`。

`teardown.sh` 默认**只出计划不动手**，`--yes` 才执行，且只删清单里 `installed` 的条目，`preexisting` 一律不碰。它还会被复制一份到 `~/github-publish-uninstall.sh`：**先删了 skill 目录也照样能清理**。

| 命令 | 效果 |
|---|---|
| `~/github-publish-uninstall.sh` | 列出将删/将留的清单 |
| `~/github-publish-uninstall.sh --yes` | 真删本次装的包、文件、配置键 |
| `~/github-publish-uninstall.sh --yes --purge-auth` | 连 `~/.config/gh` 的登录态一起删 |

一条前提要认清：包管理器层面做不到"删目录即自动卸载"，所以约定是**先跑卸载脚本，再删目录**；清单放在 skill 目录之外就是为了这个。

### 13.3 本仓库自己的例外

本仓库的 `SKILL.md` 和 scanner 本身就是在写这些痕迹词，跑 `publish` 必然出现候选。逐条确认全是文档与正则字面量之后，按 §二 的约定用 `--skip-gates` 放行——这是"人工确认后的放行"，不是把门禁关掉跳过审查。

## 变更记录

- 2026-11-18 建立：gh 安装 + 设备码授权 + 建仓 + Pages + CI + 脱敏清单。
- 2026-11-18 增补署名痕迹审查：`scripts/scan-traces.ps1`、判断表与四条原则。
- 2026-11-19 重构为「分类路由」：R/A/B/C/D/E 六类各自的入口、前置检查与脚本；写类统一四道门禁（身份/脱敏/痕迹/远端）；新增「被其他工具调用」的输入输出契约与七条约束；`publish.ps1` 补 fetch 比对、门禁、冲突拒绝、幂等；新增只读脚本 `check.ps1`；`scan-traces.ps1` 补 BOM 修掉 PS 5.1 乱码。
- 2026-11-19 补强推送链路：门禁改为扫描「已跟踪 + 未忽略的新文件」（新建文件里的密钥原本会漏过）；`publish.ps1` 新增 `-DryRun`（不碰 index 的预演）与 `-WaitCi`（按 `headSha` 匹配、拒绝拿上一次运行的结论充数）。
- 2026-11-19 明确触发边界：新增 §零（必须进来 / 不要进来 两张清单）与「命令简单不是跳过理由」的自我提醒；description 改成"会在 GitHub 上落地的动作必须走本 skill，纯本地操作不用"。
- 2026-11-22 补 bash 版：`check.sh` / `publish.sh` / `scan-traces.sh`，工具路径改为参数与 PATH 解析，Termux / Linux / macOS 可直接跑；新增 `setup.sh`（装工具并记账）与 `teardown.sh`（只删自己装的），清单落在 skill 目录之外，删目录后仍可回滚。
