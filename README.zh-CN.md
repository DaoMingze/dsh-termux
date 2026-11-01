# dsh-termux

在 Termux(Android)上运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`),无需 root。

[English](README.md) | [中文](README.zh-CN.md)

## 上游当前版本

徽章由 shields.io 在页面渲染时实时生成,始终反映 npm / nodejs.org 当下发布的版本,无需重新构建。

<!-- 维护提示:npm/pnpm 的预发布徽章钉在当前主线的 dist-tag(`next-12`)上。
任一项目发布新的大版本时,需要同步更新这里的标签。 -->

||LTS/Stable|Preview|
|---|---|---|
|[Node.js](https://nodejs.org/)|![Node.js stable](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fendoflife.date%2Fapi%2Fnodejs.json&query=%24%5B0%5D.latest&label=Node.js&prefix=v)|![Node.js stable](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fendoflife.date%2Fapi%2Fnodejs.json&query=%24%5B2%5D.latest&label=Node.js&prefix=v)|
|[npm](https://www.npmjs.com/package/npm)|![npm stable](https://img.shields.io/npm/v/npm?label=npm)|![npm pre](https://img.shields.io/npm/v/npm/next-12?label=npm%20pre)|
|[pnpm](https://www.npmjs.com/package/pnpm)|![pnpm stable](https://img.shields.io/npm/v/pnpm?label=pnpm)|![pnpm pre](https://img.shields.io/npm/v/pnpm/next-12?label=pnpm%20pre)|
|[dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)|![dsh stable](https://img.shields.io/npm/v/%40deepseek-ai/dsh?label=dsh)|![dsh pre](https://img.shields.io/npm/v/%40deepseek-ai/dsh/alpha?label=dsh%20pre)|

说明:dsh 的 `next` 标签当前与 `latest` 指向同一构建,所以预发布列改用 `alpha` 标签——即最新发布的开发线。本项目跟随 Node **active LTS** 线——两侧默认值都是 [`config`](config) 里的 `lts`(构建与设备安装同源),构建/安装时解析成具体版本;上表 Node.js 徽章跟踪的是上游,不是本项目的选择。

## 为什么这样做

在安卓上跑一个需要 glibc 的 Node 应用,一般方案是两条:要么把依赖全部对着 Termux 自带的(bionic)Node 重新编译,要么塞进 proot/glibc chroot。重新编译等于把 dsh 的整条原生依赖链 fork 成一份需要永久维护的第二构建;chroot 则多出一层转译,其文件语义与 activity 启动仍不符合安卓的规则。本项目走第三条路:在 Termux 自己的 glibc 运行时上安装**官方** Node.js linux-arm64 二进制——npm 预编译模块正是为这个构建编译的——上游 dsh 及其依赖原样运行,设备上从不编译任何东西。剩下的安卓特有问题(SELinux 链接策略、经 intent 的浏览器交接、Landlock 的 tmpdir 授权、跨站会话 cookie)只由一个小补丁集适配,随附的更新器每次运行都会重新校验它;完整清单见 [PATCHES.md](PATCHES.md)。

## 安装

> 仅支持 **arm64** 设备(几乎所有现代安卓手机都是 arm64)。

只有一条安装路径:克隆本仓库,跑安装脚本。每一件都来自它的官方来源——包来自 Termux 仓库、Node 来自 nodejs.org、dsh 来自 npm registry,补丁直接从这份 checkout 打。本项目自己发布的只有补丁集(见[更新](#更新)),安装时并不需要它。

```sh
pkg install git
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh        # 加 -y 自动接受所有提示
```

它的第一步自己装 pkg 前置(glibc-repo,再加 glibc + glibc-runner,以及 gnupg 与 patchelf),然后**从 nodejs.org 取官方 Node 构建**(默认当前 active LTS 线),先对照签名的 `SHASUMS256.txt` 校验再解包。版本由配置文件的 `node_version` 决定([配置](#配置)),单次运行可用 `DSH_NODE_VERSION=<lts|24|24.19.0>` 覆盖。接着把 ELF interpreter 指向 Termux 的 loader,提示是否卸载 pkg 安装的 node 栈(`nodejs`/`nodejs-lts`/`npm`/`pnpm`),并注册 `node`/`npm`/`npx`(运行时自带 pnpm 时一并注册)。

安装时从 npm 解析 dsh(即当时发布的最新版),补丁取自这份 checkout,然后把更新器与补丁集一起复制进运行时目录——此后日常维护不需要这份 checkout 还在原位。要拿到新补丁:`git pull` 之后重跑安装脚本,见[更新](#更新)。

### 配置

仓库根的 [`config`](config) 是安装的单一事实源:安装流水线读它,第 01 步把装上的实情写回。格式是 `key=value` 行,逐行解析、从不 `source`:

|键|写入方|含义|
|---|---|---|
|`node_version`|你|要装的 Node:`lts`(当前 active LTS 线)、裸大版本如 `24`、或精确 `X.Y.Z`。单次运行可用 `DSH_NODE_VERSION` 覆盖。|
|`npm_version`|你|`@deepseek-ai/dsh` 的 dist-tag(`latest`、`next`、`alpha`)或精确版本。单次运行可用 `DSH_VERSION` 覆盖。|
|`pnpm_version`|你|pnpm 规格——停在 `10` 线,原因见文件内注释。|
|`node_installed_version`|第 01 步|`<runtime>/node` 当前实际装的版本。|
|`node_bin`|第 01 步|该 `node` 二进制的绝对路径。|

只回写这两个 `node_*` 事实,正因为如此 `node_version=lts` 才能继续跟随 LTS 线,而不是被钉在上次装到的那个版本上。该文件受版本管理,所以安装后这两行会显示为已修改——那是安装记录,不是误改。

### 验证

```sh
dsh --version    # 打印已安装版本(跟随 npm,所以会变化)
pnpm --version   # 随运行时内置;`dsh plugin` 依赖它
dsh web --port 3080
```

`dsh web` 会打印 `http://127.0.0.1:3080` 并自动在手机浏览器中打开——启动时请让 Termux 保持**前台**(Android 10+ 会静默丢弃后台发起的 activity 启动);`dsh` 的行为与上游官方 CLI 完全一致,仅额外提供本项目添加的 `update` 命令(见[更新](#更新))。要启动其它 profile:`bash scripts/04-launch.sh --profile headless`(启动器统一传 `--profile <name>`;`web` 是默认值,并保留 `--host`/`--port`)。

## 更新

```sh
dsh update            # 交互式版本菜单(回车默认 latest)
dsh update -t next -y # 直接更新到 npm 的 next 标签,自动接受所有提示
dsh update --self     # 刷新补丁集并直接应用(不下载 npm 包)
```

`dsh update` 更新 dsh 版本并重打运行时自带的补丁集——这条路径只跟 npm 打交道。补丁走自己的通道:本项目只发布一个产物 `dsh-termux-patchset.tar.gz`(约 40 KB,内含更新器的三个脚本 + 补丁文件),作为 GitHub release。`dsh update --self` 下载它、比对内容签名,只有运行时落后才应用;`--dry-run` 只报告「有没有更新」,不动任何东西。全程不下载 dsh、Node 或 glibc——那些都在设备本地。

不想下载的话,`--patch-set <dir|tar.gz>` 直接应用你手上已有的补丁集——比如 `git pull` 之后 checkout 里的那份。

|参数|作用|
|---|---|
|`-t, --tag TAG`|直接安装某个 dist-tag(如 `next`),不弹版本菜单|
|`-v, --version VER`|直接安装某个精确版本(如 `0.1.1-rc.2`),不弹版本菜单|
|`-y, --yes`|自动接受所有提示|
|`--self`|下载本项目发布的补丁集,装成运行时的副本并应用到已安装的 dsh(不做 npm 更新;`-t`/`-v` 被忽略)|
|`--patch-set PATH`|从 PATH(含 `scripts/` + `patches/` 的目录或 `.tar.gz`)取补丁集,而不是下载;隐含 `--self`|
|`--dry-run`|与 `--self`/`--patch-set` 同用:只报告运行时是否落后,不改动任何东西|
|`--force`|与 `--self`/`--patch-set` 同用:机件未变化时也强制重打|
|(不带 `-t`/`-v`)|交互式版本菜单,回车默认 `latest`|

`dsh update` 不会重启正在运行的 `dsh web`,更新后请自己重新启动。

## 安装会在本地环境中做什么与卸载指导

安装只改动四处:把自含的运行时(Node + 打过补丁的 dsh + 更新器)解包到 `~/.local/opt/dsh-termux-runtime/`,在 `~/.local/bin/dsh` 放一个命令符号链接,在旁边注册 `node`/`npm`/`npx`(`pnpm`)shim,并在 `~/.bashrc` 追加一段带 `# dsh-termux` 标记的 PATH 配置。dsh 自己的数据(配置、会话)独立存放在 `~/.dsh/`;安装还会把实际装上的 Node 版本与路径记到 `config`。

卸载——一个脚本收干净:

```sh
bash scripts/99-uninstall.sh             # 先列清单,问一次
bash scripts/99-uninstall.sh -y          # 不再提问
bash scripts/99-uninstall.sh --dry-run   # 只列要删什么,不动手
bash scripts/99-uninstall.sh --purge     # 连 ~/.dsh(配置+会话)一起删
```

它只删本项目生成的东西:运行时、`dsh` 符号链接、带 dsh-termux 标记的 shim、`~/.bashrc` 里那段标记块(备份留在 `~/.bashrc.dsh-uninstall.bak`),以及 `config` 里的安装记录。Termux 包(`glibc`、`glibc-repo`、`gnupg`、`patchelf`)、本仓库与 `~/.dsh` 都不会被碰,除非你明确要求。想手工删的话:`rm ~/.local/bin/dsh`、`rm -rf ~/.local/opt/dsh-termux-runtime`,再删掉 `~/.bashrc` 里 `# dsh-termux` 那段。

## 常见问题

**`dsh web` 打不开浏览器?** 最常见原因:启动时 Termux 在后台——Android 10+ 会静默丢弃后台应用发起的 activity 启动。让 Termux 保持前台,或手动打开打印出的 URL。背景细节见[修复 3](PATCHES.md#fix-3-browser-handoff)。

**更新时报 "Patch does not apply / version drift"?** 说明 npm 上新发布的 dsh 改动了补丁目标文件。这是预期内的保护机制——此时 dsh 保持已安装但未打补丁,Android 上会话保存/write 工具可能报 `EACCES`。请到 [Issues](https://github.com/ErEbusE/dsh-termux/issues) 提报,或按 [PATCHES.md](PATCHES.md) 重新生成补丁。

**`dsh update` 不识别?** 快捷方式是安装时写进包装脚本的。从已退役的预构建 release(1.1.0 之前)装出来的 runtime 没有:直接运行内置更新器——`bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y`——或用 `scripts/00-setup.sh` 重装成当前布局。

**`dsh plugin` 报 "pnpm was not found"?** `dsh plugin` 会把参数转发给 pnpm(从 `PATH` 上拉起)。内置 pnpm 之前的 runtime 没有它——更新(`dsh update -y`)或重装即可获得:运行时在自己的 Node 里随包 pnpm(纯 JS 的 pnpm 10 线,设备端零下载),并在 `dsh` 旁边注册 `pnpm` 命令 shim。

**我的数据在哪里?** dsh 自身的数据在 `~/.dsh/`(上游默认);本项目的运行时在 `~/.local/opt/dsh-termux-runtime/`。

## 贡献者指南

欢迎提交 Issue 和 PR。贡献者工作流程——测试门槛(沙箱 + 真机实测)、CI、发布、更新机制内部细节——见 [CONTRIBUTING.md](CONTRIBUTING.md);每条安卓修复的原理与补丁漂移的再生流程见 [PATCHES.md](PATCHES.md)。如果用 AI 代理开发,[AGENTS.md](AGENTS.md) 是代理必须遵守的仓库协议。

## 项目结构

```text
dsh-termux/
├─ patches/                  Android 补丁(作用于 dsh 的 npm 编译产物)
├─ scripts/                  安装/更新流水线(在 Termux 上运行)
│   ├─ 00-setup.sh           入口:环境配置,驱动 01→04
│   ├─ 01-setup-glibc-node.sh   pkg 前置、从 nodejs.org 取 Node、node/npm 注册
│   ├─ 02-install-dsh.sh / 03-apply-patches.sh / 04-launch.sh
│   │                        02 从 npm 装 dsh · 03 依赖体检 + 匹配补丁
│   │                        · 04 生成 dsh 命令并启动指定 profile(默认 web)
│   ├─ 99-uninstall.sh       卸载:运行时、符号链接、shim、PATH 块
│   ├─ update-dsh.sh         更新器:npm 换版本 + 重打本地补丁集
│   └─ common.sh / patch-lib.sh  共享助手(包装脚本与 $BROWSER 打开器生成、
│                                补丁登记表;CI 复用)
├─ build/                    build-patchset.sh:打那唯一一个发布资产
├─ .github/workflows/        CI:静态门槛(verify)+ npm 补丁哨兵(patch-check)
│                            + patchset 发布(只发补丁集)
├─ .test-install/            沙箱测试体系(r3 安装流水线、r4 更新器)+ serve.sh
├─ config                    安装用什么、以及装上了什么(node_version、npm_version、
│                            pnpm_version;第 01 步会把 node_installed_version 与
│                            node_bin 写回)
├─ README.md / README.zh-CN.md   用户文档:安装 / 更新 / 卸载
├─ PATCHES.md                全部修复与适配的唯一索引 + 补丁机制
├─ CONTRIBUTING.md           贡献者工作流:测试门槛、CI
└─ AGENTS.md                 AI 代理协议(测试真实性、沙箱边界)
```

> 运行时产物(`node/`、`work/`、`downloads/`)构建在仓库之外——`~/.local/opt/dsh-termux-runtime/` 下。

## 可用性声明

这是一个小型业余项目。作者每天在一台 arm64 手机上使用它,安装、更新、各补丁和 `dsh web` 都正常工作。CI 会把补丁集应用到最新 npm 版 dsh 并在 Linux 上对新安装做启动冒烟测试,但没有任何自动化步骤真正走一遍 Termux 实机安装,预编译产物也没在第二台设备上试过。上游 dsh 迭代很快:新版本可能改动补丁目标文件——此时更新器会报错停下而不是弄坏你的安装——在补丁路径之外,安卓仍可能出现本项目从未见过的问题。使用前请备份重要数据,放低预期,并[报告你遇到的问题](https://github.com/ErEbusE/dsh-termux/issues)。

## 许可证

[MIT](LICENSE)
