# AGENTS.md — dsh-termux 开发测试协议

本文件指导在本仓库工作的 AI 代理如何测试改动（操作细节见 `.test-install/README.md`）。已纳入 git 跟踪，随仓库演进。改动仓库代码前先读本文件。

## 0. 铁律：agent 的测试 ≠ 通过测试

> 禁止默认「agent 跑一下无头/冒烟测试（语法检查、沙箱安装、CI 绿） 就算通过测试」。

- agent 侧的任何测试（`bash -n`、CI、§1 沙箱安装）只是**必要不充分**的 一层自动防护；
- 涉及安装、更新、补丁、浏览器交接等任何**会落到真机行为**的改动，最终 都必须由**人类在真实 Termux 设备上实际使用和测试**，agent 不得代替判定;
- 每次把改动交付人类审阅时，必须在**会话中**交付**最小、可照抄的手动实测 步骤**（命令、预期结果、逐步检查点）——步骤与实测结果都留在会话里， **不写入 PR**；在人类明确回复「通过/已验证」之前， 状态一律是**「待人类实测」**——不得宣称测试通过、不得合并、不得发布 release；
- 若改动确实无法真机验证（如无设备），必须如实标注「未实测」， 绝不能假装通过，也不能把 agent 跑过的自动测试冒充为人类实测结果。

## 1. 沙箱测试方案（.test-install/）

测试体系的**操作细节**（路线表、断言分级、baseline 管理、serve.sh 用法、 沙箱边界、历史教训、新增路线步骤）单点住在 **`.test-install/README.md`**—— 跑测试或改测试体系前必读。这里只留每个会话都需要的不变量：

- **唯一入口**：`bash .test-install/run.sh all`（= r4；`--with-r3` 追加 r3）；改安装管线时跑 `run.sh r3`；忘了命令敲 `run.sh help`；
- **维护者工具**：可复用的本地工具一律放 `.test-install/tools/`——该目录是 **整目录白名单**，工具放进来即自动纳入版本管理，不必逐文件改 `.gitignore`； 一次性脚本不留存、不散落在 `.test-install/` 根目录（先例：`intent-token-probe.sh` 曾以未纳管状态游离，现移入 `tools/`）。工具清单见 `.test-install/README.md`；
- **人类实测**：`bash .test-install/serve.sh`（自动层门槛全绿才起沙箱 Web， 端口 3141；`WITH_CREDS=1` 带凭据实测聊天）——安装/更新类改动的**最终判定** 是 serve.sh 点检清单逐项确认，缺项必须标「未实测」； **人类实测同样必须经 serve.sh 的沙箱环境**，交付的实测步骤绝不允许指向 本地正在运行的 dsh runtime/`~/.dsh`/`~/.bashrc`（教训：曾两次把实测清单写成直改本地正在运行的安装， 被人肉纠正）；对本地正在运行的 dsh runtime 的升级只作为最后一步，执行的是沙箱里已验证过的产物；
- **沙箱边界（永不可触碰本地正在运行的 dsh runtime）**：沙箱期间 HOME/TMPDIR/DSH_* 必须指向沙箱内； 严禁改动/删除/重装本地正在运行的 `~/.local/opt/dsh-termux-runtime/`、`~/.local/bin/dsh`、 `~/.bashrc`、`~/.dsh`；`grun` 用 stub；
- **判定标准**：任何断言失败即 FAIL，禁止「只跑个大概」；每条路线结束打印 `== [rN] done: N ok ==` 与集中 WARN；
- **基线纪律**：`baseline.env`（已入 git）在方案A 退役后**冻结**在最后一份已发布产物上，只作 r4 的种子；它不再有新版，`run.sh baseline set` 只在需要换一份历史产物时才用，且属于需要 review 的改动；
- 测试代码已纳入版本管理（代码跟踪、数据 ignore）——改动测试体系与改动 仓库代码同等对待：同 PR、同 review。唯一例外是上面的机械 baseline re-pin；其余任何 `.test-install` 改动（路线代码、断言、沙箱边界——凡含 判断内容者）不得享受该豁免。

## 2. 上游 dsh 源码与 GitHub Token

### 上游源码位置

- 上游 DeepSeek Harness 的**完整源码**检出于 `~/vibe-coding/dsh-source`（monorepo： CLI 在 `apps/cli`，其命令行定义在 `apps/cli/src/args.ts`；各包在 `packages/`）。 本项目交付的一切断言（例如「上游没有 update 子命令」）以这份源码为准；
- **npm 包 ≠ 源码**：设备上运行的是 npm 编译产物 （`~/.local/opt/dsh-termux-runtime/work/node_modules/@deepseek-ai/`），打补丁、 验 marker 都针对它——查问题先分清该看哪边；
- 源码树与安装产物是两个独立世界：在本仓库工作时只读引用源码做对照，不构建、 不改动、不在其中跑本项目的脚本。

### GitHub Token（维护者：获取与使用）

- **存放位置**：`~/.config/dsh-termux/.env`（仓库**外**、gitignored 之外的 用户配置文件目录；文件权限 600），内容形如 `export GH_TOKEN=…`。 值**永不打印、永不进提交**，文档/日志只允许出现键名 `GH_TOKEN`；
- **装载**：不自动加载；需要时手动 `source ~/.config/dsh-termux/.env` （或 `set -a; . ~/.config/dsh-termux/.env; set +a`）；
- **获取**：GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) 新建，勾选 `repo`（或 fine-grained：仅本仓库 + Contents 读写）；生成后一次性复制进 `.env`；
- **使用场景（三层分工，按消费者分，不是二选一）**：
  - **维护者会话（人或 agent）**：GitHub 操作统一走 `gh` CLI —— 它是唯一界面， 自动读取环境里的 `GH_TOKEN`（`source` 之后无需 `gh auth login`）。不要手写 GitHub API 调用：裸 API 的 302 签名 URL 会拒绝被转发的 `Authorization`， 引号与分页也要自己兜。常用：`gh pr create/checks/merge`、 `gh run view <id> --log-failed`、`gh release view`；带 trailer 的合并用 `.test-install/tools/pr-merge.sh`（§6.3）；
  - **设备侧脚本**（`00-04`、`update-dsh.sh`、`patch-lib.sh` 等）： **禁止**依赖 `gh`；只用 `curl` 打公开端点（nodejs.org、npm registry），公开下载**不需要** token；
  - **CI**：`.github/workflows/release.yml` 里那行 `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` 用的是 Actions **自动注入**的令牌，与本地 `.env` 无关（按键名 grep，不钉行号—— 行号会随同文件的增删而腐烂：本行曾从 42 改到 47，实际已是 50）；
  - `~/.config/dsh-termux/.env` 与 `~/.profile` 里的 `https_proxy` 互不影响， 两者按需分别装载。

## 3. Termux 环境识别与目录禁忌

在 Termux 里工作的第一原则：先确认自己是不是在 Termux 环境中；如果是， 就**不要**访问 Android 禁止访问的目录（最典型的是系统根 `/tmp`）。

- **如何检查是否在 Termux**（满足其一即可）：
  - `$PREFIX` 已导出且 `$PREFIX/bin` 存在（Termux 下 `PREFIX=/data/data/com.termux/files/usr`）；
  - `uname -o` 输出 `Android`；
- **若在 Termux，禁止访问 Android 禁止目录（如 `/tmp`）**：
  - 直接读写多为 `Permission denied`；部分路径会被 SELinux/沙箱**静默拒绝**， 症状像「命令没跑/没生效」而不是报错，极易误判为代码问题；
  - Termux 自己的临时目录是 `$PREFIX/tmp` （即 `/data/data/com.termux/files/usr/tmp`），**不是** `/tmp`； 但该目录同样可能因权限/沙箱策略被拒（实测 `mktemp` 落在其中会被拒）；
  - **规律**：临时文件/测试目录一律放「工作区/沙箱内」。本仓库为 `.test-install/sandbox-*/tmp`；`TMPDIR`/`TMP` 由 sandbox-lib.sh 的 隔离导出与 serve.sh 强制覆盖到沙箱内，不依赖任何系统 tmp；
  - 脚本里 `mktemp`/`mkdir` 落点必须显式 `cd "$D" || exit 1` 守卫 + 落点确认， 绝不写死系统路径（教训：无守卫的临时目录测试曾在仓库根目录误覆盖文件）。

## 4. 测试场景矩阵（r3 / r4）

方案A（从 GitHub release 装预构建运行时）已退役：仓库不再产出 `install.sh` 与运行时 tarball，安装只有一条路——`00-setup.sh`，包来自 Termux 仓库、Node 来自 nodejs.org、dsh 来自 npm、补丁来自 checkout。**唯一发布的产物是补丁集** `dsh-termux-patchset.tar.gz`（`build/build-patchset.sh` 打，`release.yml` 在 `patches/**` 或 `patch-lib.sh` 变化时自动发），身份是内容签名而非版本号。`baseline.env` 因此**冻结**在最后一份已发布运行时产物上，只作 r4 的种子，不再有新版。

|路线|入口|测什么（断言失败即 FAIL）|
|---|---|---|
|R3 setup 管线|`run.sh r3`|工作区 `00-setup.sh` 01(pkg 前置+nodejs.org 取 node+config 读写+shim 注册)→02(npm 装 dsh)→03(树体检+补丁)→04(wrapper+profile 启动)（web 跳过）；设备侧不碰本项目任何发布产物|
|R4 更新链路|`run.sh r4`|种子(冻结发布物解包)→ 工作区 `scripts/update-dsh.sh -t <tag> -y`：npm 重装 + 用 checkout 的补丁集重打 + wrapper/opener/symlink 重写 + 钩子存活（`--self` 的下载/签名/应用链路目前无自动化覆盖，见下）|

交付门槛 = `bash .test-install/run.sh all`（= r4；改 00-04 管线时加 `--with-r3`）。**`--self`（下载补丁集 → 比对签名 → 应用）没有被任何路线覆盖**，改它必须人工演练并如实标「未实测」。新增路线的步骤见 `.test-install/README.md`（routes/ 驱动 + run.sh 登记 + README 路线表）。

- **CI 分工（按「改动能破坏什么」分流，不是按提交类型分）**：
  - `.github/workflows/verify.yml` —— 每个 PR / push main 必跑、不联网装包、 目标 1 分钟内出结果：全部受跟踪 `*.sh` 的 `bash -n` + ShellCheck （门槛 `-S warning`；`-P SCRIPTDIR` 让 `# shellcheck source=` 指令可解析， 库里的变量与函数才被真正跟进去看。**注意版本偏差**：runner 自带 0.9.0、 Termux 是 0.11.0，两者发现集不同——本地绿不等于 CI 绿，**以 CI 为准**， 步骤里打印的 version 行就是用来一眼归因的）、`DSH_PATCH_SET` 与 `patches/` 的静态一致性、wrapper/opener 生成器、`common.sh` 的 interpreter 补丁守卫、 `update-dsh.sh` 帮助哨兵契约（`-h` 输出 == `# help-begin`/`# help-end` 之间的块）、`.test-install/run.sh` 入口与路线登记、 文档相对链接/锚点（`.github/scripts/check-doc-links.py`）；
  - `.github/workflows/release.yml` —— **只发补丁集**：`patches/**`、`scripts/patch-lib.sh`、`build/build-patchset.sh` 变化时（或手动 dispatch）打 `dsh-termux-patchset.tar.gz` 并发布，tag 形如 `patches-<YYYYMMDD>-<sha7>`；同一 tag 已存在则跳过。**不建 node/npm、不出运行时产物**，~1 分钟；
  - `.github/workflows/patch-check.yml` —— npm 装 dsh → 套补丁 → 校验 marker → 回归守卫 → boot smoke（~16min，其中 npm 占 98%）。触发点是**它真正能派上 用场的时刻**：`patches/`、`scripts/patch-lib.sh`、`config` 变化时；以及手动 dispatch（改动补丁前后各跑一次）。 **没有 cron**：定时轮询无论上游动没动都要占一条运行记录，而它防的失败很轻—— `update-dsh.sh` 与 `00-setup.sh` 在补丁打不上时都会响亮停下，没人会拿到坏 安装，维护者只是「下次更新时才知道」而不是「第二天早上就知道」；
  - main 已启用分支保护：required check = `static`（**不要**把 `patch-check` 设为 required——路径过滤的工作流不运行时会永久 pending）， `enforce_admins` 关闭以保留 §1/§6.4 的直推豁免；
  - 它们都**不**替代 §1 沙箱与 §0 真机实测。
- **补丁链路**：CI 的 patch 检查（对 npm 最新版 apply + boot smoke）见上， 本地改动 `scripts/patch-lib.sh` 或 `patches/` 时至少 `bash -n`， 再按需在隔离 HOME 演练 `scripts/0x-*.sh` 各步骤；R4 的补丁标记断言 （marker 由 `DSH_PATCH_SET` 条目声明，不再是硬编码单词）同时覆盖 「补丁对新版本 dsh 仍可重打」。 条目可带**第四段适用性前置条件**（`<patch>:<rel>:<marker>:<precondition>`）： 被修的上游代码不在该 dsh 版本里时整条补丁跳过、marker 不作要求——它让 「只存在于新版 dsh 的修复」不至于把稳定渠道的安装全部打红（先例：补丁 6 的 `SameSite`，见 `PATCHES.md`）。默认三段式仍是**强制**：打不上就停。 条件条目在 CI 自动跑的 `latest` 上只会报「不适用」，真验证要用 `patch-check` 的 `workflow_dispatch` 指向 `@deepseek-ai/dsh@alpha`。

## 5. 各改动类型的测试门槛

|改动类型|agent 必做（自动层）|人类实测（最终判定，必做）|
|---|---|---|
|00-04 管线 / common.sh / wrapper / opener|bash -n + shellcheck + `run.sh r3`（改动 wrapper 生成器时另跑 r4 验钩子存活）|沙箱点检 `bash .test-install/serve.sh`（点检清单见其启动输出与 `.test-install/README.md`）；发布前建议再真机完整安装一次|
|patch-lib.sh / patches/|bash -n + shellcheck + CI（verify 的静态登记表检查 + 自动触发的 patch-check）+（改 patches 时）`run.sh r4`|真机 `dsh web` 会话保存（write 工具）+ 浏览器交接|
|update-dsh.sh|bash -n + shellcheck（CI 另查帮助哨兵契约）+ `run.sh r4`；`--self` 本地的语义目前无自动化覆盖，需人工演练|真机执行一次真实更新并验收（含 `dsh update --self` 与本地 `--patch-set`）|
|00-setup.sh / 01-04 管线|bash -n + shellcheck + `run.sh r3`|真机完整跑一次 `00-setup.sh -y` 并验收 dsh web|
|.test-install/ 测试体系|bash -n + shellcheck + CI verify（入口与路线登记）+ 实跑受影响路线|视被测路线而定；改测试体系本身不产生新的真机项|
|CI 工作流（verify / patch-check）|本地语法/逻辑走查 + 在 PR 上**实际看运行**（该跑的跑了、不该跑的没跑）|无额外真机项|
|纯文档|`python3 .github/scripts/check-doc-links.py`（CI 同款）+ 链接/锚点核对|无强制，但措辞类改动仍建议人类过目|

## 6. 交付与提交流程

1. 自动层全绿（`bash -n` / CI / 沙箱）后，把改动交给人类审阅；
2. 实测步骤在**会话中**交付指导（步骤与实测结果都不进 PR 正文），形如：

   ```sh
   # 1) 完整安装（真机）
   git clone https://github.com/ErEbusE/dsh-termux.git && cd dsh-termux
   bash scripts/00-setup.sh -y
   #    预期: … ; 检查: dsh --version; dsh web --port 3080 并在浏览器打开
   # 2) 更新（如涉及）
   bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y
   #    检查: 版本变化、dsh web 正常
   # 3) 回滚/清理（如提供）
   ```

3. 人类复核并实测确认后，才允许提交 / 合并 / 发布； 安装类改动以 serve.sh 点检清单逐项回复作为实测凭据，缺项必须标「未实测」； 合并时把实测凭据写成 `Tested-by:` trailer 带进合并（或末位）提交—— git 历史即永久留痕，PR 正文保持干净（`git log --grep='^Tested-by:'` 可检索）， 形如 `Tested-by: ErEbusE [on-device: full gate + serve.sh checklist @9a75ac2, 2026-08-31 15:40+08:00]`—— `@哈希` 为被测分支 tip（与 `git show <merge>^2` 互为印证），时刻取本地时间含时区 （时刻 `date '+%F %R%:z'`、哈希 `git rev-parse --short`；仓库内一步组装： `bash .test-install/tools/tb.sh "<实测覆盖面一句话，如 'r3 + r4'>" [tree-ish]`； **没有真机面**的改动（纯 CI / 纯工作流）用 `tb.sh --review "<范围>"`，标签变 `review`、凭据是审阅 + CI 绿——能落到设备上的改动一律用默认 `on-device`， 用 review 蒙混等同于 §0
   禁止的「拿自动测试冒充实测」； 合并动作本身用 `bash .test-install/tools/pr-merge.sh <PR号> "<范围>"`（默认 dry-run 只打印将写入的合并提交信息，`--yes` 才执行；它内部调 `tb.sh` 生成 trailer 写进 merge commit）——**手拼 trailer 视为流程错误**； 更多示例见 `.test-install/README.md`「合并留痕」）；
4. 小文档直推仅限「PR 合并后的收尾修正」量级：**个别文件、数行以内**、 不触及任何代码行为，且**不触碰 `.test-install/` 内的代码文件**（其中的 注释/文案字符串随代码同 review）；跨文件的成体系文档修改（如 `b7c759c` 的全仓术语清扫）仍走分支+PR。前提：内容已在会话中经人类确认；无需 Tested-by（无可实测项）——先例 `1c9c869`、`2f35f26`；
5. 提交信息用英文、conventional 前缀（refactor/fix/feat/docs/ci/housekeeping）；
6. 发布只有一条通道：补丁集。`release.yml` 在补丁变更时自动发 `dsh-termux-patchset.tar.gz`，身份是**内容签名**（`dsh_patch_set_signature`），没有 `VERSION` 文件、也没有 tag 尾段派生链。运行时可安装产物（`install.sh` / 运行时 tarball / pre 渠道）**已彻底退役**——要恢复它得连装配、校验与测试种子一起恢复，不是把 workflow 从历史里捡回来。
