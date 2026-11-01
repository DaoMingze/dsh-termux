# dsh-termux

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) on Termux (Android), no root required.

[English](README.md) | [中文](README.zh-CN.md)

## Current upstream versions

Badges are rendered live by shields.io at view time — they always reflect what npm / nodejs.org serve right now, no rebuild needed.

<!-- Maintenance note: the npm/pnpm prerelease badges pin the current major line's
dist-tag (`next-12`). When either project ships a new major, bump the tag here. -->

||LTS/Stable|Preview|
|---|---|---|
|[Node.js](https://nodejs.org/)|![Node.js stable](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fendoflife.date%2Fapi%2Fnodejs.json&query=%24%5B0%5D.latest&label=Node.js&prefix=v)|![Node.js stable](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fendoflife.date%2Fapi%2Fnodejs.json&query=%24%5B2%5D.latest&label=Node.js&prefix=v)|
|[npm](https://www.npmjs.com/package/npm)|![npm stable](https://img.shields.io/npm/v/npm?label=npm)|![npm pre](https://img.shields.io/npm/v/npm/next-12?label=npm%20pre)|
|[pnpm](https://www.npmjs.com/package/pnpm)|![pnpm stable](https://img.shields.io/npm/v/pnpm?label=pnpm)|![pnpm pre](https://img.shields.io/npm/v/pnpm/next-12?label=pnpm%20pre)|
|[dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)|![dsh stable](https://img.shields.io/npm/v/%40deepseek-ai/dsh?label=dsh)|![dsh pre](https://img.shields.io/npm/v/%40deepseek-ai/dsh/alpha?label=dsh%20pre)|

Note: dsh's `next` dist-tag currently points at the same build as `latest`, so the prerelease column shows the `alpha` tag — the freshest published line. This project follows the Node **active LTS** line — `lts` in [`config`](config) is the default, resolved to a concrete release at install time; the Node.js badges above track upstream, not this choice.

## Why this approach

The usual ways to run a glibc Node app on Android are recompiling everything against Termux's own (bionic) Node, or a proot/glibc chroot. Recompiling forks dsh's entire native dependency chain into a second build you must maintain forever; a chroot adds a translation layer whose file semantics and activity launches still do not match Android's rules. dsh-termux instead ships the **official** Node.js linux-arm64 binary — the exact build npm's prebuilt modules were compiled for — on Termux's own glibc runtime, so upstream dsh and its dependencies run unmodified and nothing is ever compiled on-device. Only a small patch set adapts the Android-specific problems that remain (SELinux link policy, intent-based browser handoff, Landlock tmpdir grants, cross-site session cookies), and the bundled
updater re-verifies it on every run; the complete index is [PATCHES.md](PATCHES.md).

## Installation

> Only **arm64** devices are supported (nearly all modern Android phones are arm64).

There is exactly one install path: clone this repo and run the setup script. Every piece comes from its official source — packages from Termux's repos, Node from nodejs.org, dsh from the npm registry — and the patches are applied straight out of the checkout. The only thing this project itself publishes is the patch set (see [Updating](#updating)); it is not needed to install.

```sh
pkg install git
git clone https://github.com/ErEbusE/dsh-termux.git
cd dsh-termux
bash scripts/00-setup.sh        # add -y to auto-accept every prompt
```

Its first step installs the pkg prerequisites itself (glibc-repo, then glibc + glibc-runner, plus gnupg and patchelf), then fetches the **official Node build from nodejs.org** — the active LTS line by default — checking it against the signed `SHASUMS256.txt` before anything is unpacked. Which version that is comes from `node_version` in the config file (see [Configuration](#configuration)), overridable per run with `DSH_NODE_VERSION=<lts|24|24.19.0>`. It then points Node's ELF interpreter at Termux's loader, offers to remove a pkg-installed node stack (`nodejs`/`nodejs-lts`/`npm`/`pnpm`), and registers `node`/`npm`/`npx` (+`pnpm` when the runtime bundles it).

The setup installs dsh from npm at install time (whatever is published right then), applies the patches from this checkout, and copies both the updater and the patch set into the runtime directory — so maintaining the install later does not require the checkout to stay in place. To pick up new patches, `git pull` and run the setup again; see [Updating](#updating).

### Configuration

[`config`](config) in the repo root is the single source of truth for the install: the setup pipeline reads it, and `01` writes the installed facts back. Plain `key=value` lines, parsed one at a time and never sourced:

|Key|Written by|Meaning|
|---|---|---|
|`node_version`|you|Node to install: `lts` (the active LTS line), a bare major such as `24`, or an exact `X.Y.Z`. `DSH_NODE_VERSION` overrides it for one run.|
|`npm_version`|you|`@deepseek-ai/dsh` dist-tag (`latest`, `next`, `alpha`) or an exact version. `DSH_VERSION` overrides it for one run.|
|`pnpm_version`|you|pnpm spec — stays on the `10` line for the reason in the file's comment.|
|`node_installed_version`|step 01|What is actually in `<runtime>/node` right now.|
|`node_bin`|step 01|Absolute path to that `node` binary.|

Only the two `node_*` facts are written back, which is what lets `node_version=lts` keep following the LTS line instead of freezing at whatever happened to be installed. The file is tracked, so an install leaves those two lines modified in `git status` — that is the record, not an accident.

### Verify

```sh
dsh --version    # prints the installed version (tracks npm, so it changes)
pnpm --version   # bundled in the runtime; required by `dsh plugin`
dsh web --port 3080
```

`dsh web` prints `http://127.0.0.1:3080` and opens it in your phone's browser — keep Termux in the **foreground** while starting it (Android 10+ silently drops background activity launches); the `dsh` command behaves exactly like the official upstream CLI, plus the `update` command added by this project (see [Updating](#updating)). For any other profile, `bash scripts/04-launch.sh --profile headless` (the launcher passes `--profile <name>`; `web` is the default and keeps `--host`/`--port`).

## Updating

```sh
dsh update            # interactive version menu (Enter defaults to latest)
dsh update -t next -y # straight to the npm `next` dist-tag, prompts auto-accepted
dsh update --self     # refresh the patch set and apply it (no npm download)
```

`dsh update` moves the dsh version and re-applies the patch set the runtime carries — that path never leaves npm. Patches move on their own channel: this project publishes exactly one artifact, `dsh-termux-patchset.tar.gz` (~40 KB — the updater's three scripts plus the patch files), as a GitHub release. `dsh update --self` downloads it, compares content signatures and applies it only when the runtime is behind; `--dry-run` tells you whether an update exists without touching anything. No dsh, Node or glibc download is involved — those live on the device.

If you would rather not download anything, `--patch-set <dir|tar.gz>` applies a set you already have — the one in your checkout, after `git pull`.

|Flag|Effect|
|---|---|
|`-t, --tag TAG`|install a dist-tag directly (e.g. `next`), no version menu|
|`-v, --version VER`|install an exact version directly (e.g. `0.1.1-rc.2`), no version menu|
|`-y, --yes`|auto-accept every prompt|
|`--self`|fetch the published patch set, install it as the runtime's copy and apply it to the installed dsh (no npm update; `-t`/`-v` are ignored)|
|`--patch-set PATH`|take the patch set from PATH (a directory or `.tar.gz` with `scripts/` + `patches/`) instead of downloading; implies `--self`|
|`--dry-run`|with `--self`/`--patch-set`: report whether the runtime is behind, change nothing|
|`--force`|with `--self`/`--patch-set`: re-apply even when the machinery is already current|
|(no `-t`/`-v`)|interactive version menu, Enter defaults to `latest`|

`dsh update` never restarts a running `dsh web` — start it again yourself afterwards.

## What installation changes — and how to uninstall

Installation touches exactly four places: it unpacks the self-contained runtime (Node + patched dsh + updater) into `~/.local/opt/dsh-termux-runtime/`, symlinks the `dsh` command at `~/.local/bin/dsh`, registers the `node`/`npm`/`npx` (`pnpm`) shims next to it, and appends one PATH block tagged `# dsh-termux` to `~/.bashrc`. dsh's own data (config, sessions) is separate, under `~/.dsh/`; the install also records the Node version and path it installed in `config`.

Uninstall — one script removes all of it:

```sh
bash scripts/99-uninstall.sh             # shows the plan, asks once
bash scripts/99-uninstall.sh -y          # no prompts
bash scripts/99-uninstall.sh --dry-run   # what would go; nothing is removed
bash scripts/99-uninstall.sh --purge     # also ~/.dsh (config + sessions)
```


It removes only what this project created — the runtime, the `dsh` symlink, shims carrying the dsh-termux marker, the tagged `~/.bashrc` block (backup kept as `~/.bashrc.dsh-uninstall.bak`) and the install record in `config`. Termux packages (`glibc`, `glibc-repo`, `gnupg`, `patchelf`), this repo checkout and `~/.dsh` stay unless you ask for them. Doing it by hand instead: `rm ~/.local/bin/dsh`, `rm -rf ~/.local/opt/dsh-termux-runtime`, and delete the `# dsh-termux` block from `~/.bashrc`.

## FAQ

**`dsh web` doesn't open the browser?** Most common cause: Termux was in the background — Android 10+ silently drops activity launches from background apps. Keep Termux in the foreground, or open the printed URL manually. Background details: [Fix 3](PATCHES.md#fix-3-browser-handoff).

**Update stopped with "Patch does not apply / version drift"?** A newly published dsh changed the patched files. This is the intended safety stop — dsh stays installed but unpatched, so session saves and the write tool may fail with `EACCES` on Android. File an [issue](https://github.com/ErEbusE/dsh-termux/issues) or regenerate the patches per [PATCHES.md](PATCHES.md).

**`dsh update` unknown?** The shortcut is baked into the wrapper at install time. A runtime installed from the retired prebuilt releases (before 1.1.0) has none: run the bundled updater directly — `bash ~/.local/opt/dsh-termux-runtime/scripts/update-dsh.sh -t next -y` — or reinstall with `scripts/00-setup.sh` to get the current layout.

**`dsh plugin` says "pnpm was not found"?** `dsh plugin` forwards its arguments to pnpm (spawned off `PATH`). Runtimes from releases before pnpm bundling shipped no pnpm — update (`dsh update -y`) or reinstall to get it: the runtime carries pnpm inside its own Node (the pure-JS pnpm 10 line, no device-side download) and registers a `pnpm` command shim next to `dsh`.

**Where is my data?** dsh data lives in `~/.dsh/` (upstream default); this project's runtime in `~/.local/opt/dsh-termux-runtime/`.

## Contributing

Issues and PRs are welcome. The contributor workflow — testing gates (sandbox + on-device), CI, releases, and the update mechanism internals — is in [CONTRIBUTING.md](CONTRIBUTING.md); how every Android fix works and how to regenerate drifted patches is in [PATCHES.md](PATCHES.md). If you develop with AI agents, [AGENTS.md](AGENTS.md) is the repo protocol they follow.

## Project layout

```text
dsh-termux/
├─ patches/                  Android patches (over dsh's compiled npm lib files)
├─ scripts/                  install/update pipeline (runs on Termux)
│   ├─ 00-setup.sh           entry point: env config, drives 01→04
│   ├─ 01-setup-glibc-node.sh   pkg prerequisites, Node from nodejs.org, node/npm shims
│   ├─ 02-install-dsh.sh / 03-apply-patches.sh / 04-launch.sh
│   │                        02 dsh from npm · 03 tree check + matching patches
│   │                        · 04 the `dsh` command + launch a profile (web)
│   ├─ 99-uninstall.sh       removes the runtime, the symlink, the shims and the PATH block
│   ├─ update-dsh.sh         updater: npm version switch + re-apply the local patch set
│   └─ common.sh / patch-lib.sh  shared helpers (wrapper & $BROWSER generators,
│                                patch registry; reused by CI)
├─ build/                    build-patchset.sh: packs the one published asset
├─ .github/workflows/        CI: static gate (verify) + npm patch canary (patch-check)
│                            + patchset release (the patch set, and nothing else)
├─ .test-install/            sandboxed test harness (r3 setup pipeline, r4 updater) + serve.sh
├─ config                    what the install uses and what it installed (node_version,
│                            npm_version, pnpm_version; step 01 writes node_installed_version
│                            + node_bin back)
├─ README.md / README.zh-CN.md   user docs: install / update / uninstall
├─ PATCHES.md                single index of all fixes & adaptations + patch mechanics
├─ CONTRIBUTING.md           contributor workflow: testing gates, CI
└─ AGENTS.md                 AI-agent protocol (testing truth-claims, sandbox boundary)
```

> Runtime artifacts (`node/`, `work/`, `downloads/`) are built outside this repository, under `~/.local/opt/dsh-termux-runtime/`.

## Availability statement

Small hobby project. The author runs it daily on one arm64 phone, where install, update, the patches and `dsh web` all work. CI applies the patch set to the newest npm dsh and boot-smokes a fresh install on Linux, but no automated step ever walks a real Termux install, and the install has not been tried on a second device. Upstream dsh moves fast: a new release can change the patched files — the updater then stops with an error instead of breaking your install — and outside the patched paths Android can still surface problems this project has never seen. Back up anything important, keep expectations modest, and [report what breaks](https://github.com/ErEbusE/dsh-termux/issues).

## License

[MIT](LICENSE)
