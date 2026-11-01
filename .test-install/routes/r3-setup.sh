#!/data/data/com.termux/files/usr/bin/bash
# r3-setup.sh — R3 setup 管线测试: 驱动工作区 scripts/00-setup 流水线（拆步调用）。
# [01] 真机 pkg 前置 + nodejs.org 官方 node + glibc 补丁 + node/npm shim 注册
#      -> [02] npm 装 @deepseek-ai/dsh (--ignore-scripts)
#      -> [03] dsh 树体检 + 补丁集 -> [04] wrapper/opener/symlink + profile 启动。
# 这是与 build/install.sh 并行的第二种安装方案 (dsh 来自 npm registry, 不经 tarball)。
# 需要网络: npm registry + nodejs.org。注意 [02] 冷装全量解析约 20min+ 才可能完成
# (依赖图在 arm64 冷解析的正常耗时; 先跑过一次 r4 会热缓存), 别误判为挂死。
set -uo pipefail
# ROUTE 先于 source: 库里写的是 ROUTE="${ROUTE:-}", 本就允许调用者预设,
# 而这个顺序让「谁用了它」对读者和 shellcheck 都成立。
ROUTE="r3"
# shellcheck source=../sandbox-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sandbox-lib.sh"

load_baseline
check_baseline_consistent

# --- 前置: 真机 pkg 前置必须在场 (否则 01 会触发 pkg install 的真机变更) ---
# 判定口径与 01 一致: glibc 两个包按 dpkg, grun/patchelf/gpg 按二进制在场
# (glibc-runner 自带 patchelf, 未必有独立的 dpkg 条目)。
echo "=== 0. preflight 真机 pkg 前置 ==="
[ -x /data/data/com.termux/files/usr/glibc/bin/grun ] ||
	fail "真机 glibc-runner 缺失 (先真机: pkg install glibc-runner)"
for p in glibc glibc-repo gnupg; do
	dpkg -s "$p" >/dev/null 2>&1 ||
		fail "真机缺 dpkg 包 $p (01 会试图 pkg install, 沙箱里不允许)"
done
for b in grun patchelf gpg; do
	command -v "$b" >/dev/null 2>&1 ||
		fail "真机缺命令 $b (01 会试图 pkg install, 沙箱里不允许)"
done
ok "pkg 前置齐备 (glibc/glibc-repo/gnupg + grun/patchelf/gpg)"

sandbox_init "${DSH_SANDBOX:-setup}" --work
export DSH_NODE_VERSION="24.19.0" # r3 自己钉死被测 node 版本 (仓库默认是 lts = active
# LTS 线, 会随上游换代而变; 测试要可复现, 所以这里显式给精确版本, 不跟仓库默认值)。
# 基线 node 已补丁, 这里取的是官方原版, 顺便验证 01 的下载+patchelf 链路。
# 被测 dsh 渠道由调用者用 DSH_VERSION 指定 (npm spec, 默认 @deepseek-ai/dsh@latest,
# 见 scripts/02-install-dsh.sh); DSH_SANDBOX 指名沙箱 (默认 setup)。
# serve.sh 的 DSH_TARGET=<dist-tag> 就靠这两个构建「工作区补丁集 × 非稳定渠道」。
# 为什么是这条链路而不是 r4 (更新器): update-dsh.sh 的补丁集**永远来自最新稳定
# release** —— 它 self_update 时会从那个 release 拉 patches/ 覆盖 runtime 再
# re-exec 那份旧 updater。于是 `-t alpha` 的实际含义变成「用稳定版的补丁去打
# alpha 的 lib」, 补丁一漂移必红 (2026-09-08 实测坐实)。r3 的 [02][03] 没有更新器,
# 装的渠道与打的补丁集各自独立, 才是渠道测试该走的路。

echo "=== 1. [01] 取官方 node + glibc 补丁 (nodejs.org) ==="
bash "$TI_ROOT/../scripts/01-setup-glibc-node.sh" -y >"$ROOT/01.log" 2>&1 ||
	{
		cat "$ROOT/01.log"
		fail "[01] exited non-zero"
	}
[ -x "$NODE" ] || fail "node missing after [01]"
readelf -l "$NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "node not glibc-patched"
NV="$("$NODE" --version 2>"$ROOT/node-err.log")" || {
	cat "$ROOT/node-err.log" >&2
	fail "patched node won't run"
}
ok "[01] node 取得并补丁 ($NV)"

# [01] 现在自己收尾: 注册 glibc node/npm/npx(+pnpm) shim, 并把 bin dir 写进
# ~/.bashrc (这两件事原先在 [04])。
for s in node npm npx; do
	[ -x "$ROOT/bin/$s" ] || fail "[01] 后 shim $s missing (注册未发生或落点不对)"
done
grep -q '# dsh-termux' "$ROOT/home/.bashrc" || fail "[01] bashrc tag missing"
grep -q "export PATH=\"$ROOT/bin:\$PATH\"" "$ROOT/home/.bashrc" || fail "[01] PATH line missing"
SVER="$("$ROOT/bin/node" --version 2>"$ROOT/shim-node-err.log")" ||
	{
		cat "$ROOT/shim-node-err.log" >&2
		fail "[01] node shim 无法直连运行"
	}
ok "[01] node/npm/npx shim + bashrc PATH 就位 (shim node $SVER)"

echo "=== 1b. [01] 默认路径: node 取自 release tarball (离线, 用基线资产) ==="
# 01 的默认 node 来源是 release 运行时 tarball (与发布物的原生件同一次构建);
# 上面 §1 走的是 nodejs.org 覆盖路径 (DSH_NODE_VERSION)。这里用基线 tarball 当
# 「本地已下载的发布物」(DSH_RELEASE_TARBALL) 来验默认路径: 解包 node/ + 打
# interpreter + marker, 全程不联网。基线资产不在场或哈希不符时只记 note, 不让
# r3 依赖一次 100MiB 下载才能跑。
rel_asset_ok=0
if [ -f "$TARBALL" ]; then
	if [ "$(sha256sum "$TARBALL" | awk '{print $1}')" = "$TARBALL_SHA256" ]; then
		rel_asset_ok=1
	else
		note "基线 tarball 哈希与 baseline.env 不符, 跳过 [01b] (先 run.sh baseline set)"
	fi
fi
if [ "$rel_asset_ok" = 1 ]; then
	REL_PREFIX="$ROOT/prefix-rel"
	REL_BIN="$ROOT/bin-rel"
	DSH_RUNTIME_DIR="$REL_PREFIX" DSH_BIN_DIR="$REL_BIN" \
		DSH_RELEASE="$BASELINE_TAG" DSH_RELEASE_TARBALL="$TARBALL" \
		bash "$TI_ROOT/../scripts/01-setup-glibc-node.sh" -y >"$ROOT/01b.log" 2>&1 ||
		{
			cat "$ROOT/01b.log"
			fail "[01b] exited non-zero"
		}
	REL_NODE="$REL_PREFIX/node/bin/node"
	[ -x "$REL_NODE" ] || fail "[01b] node missing in $REL_PREFIX"
	readelf -l "$REL_NODE" | grep -q 'ld-linux-aarch64.so.1' || fail "[01b] extracted node not glibc-patched"
	REL_V="$("$REL_NODE" --version 2>"$ROOT/01b-node-err.log")" ||
		{
			cat "$ROOT/01b-node-err.log" >&2
			fail "[01b] extracted node won't run"
		}
	# marker 决定复用: 必须是具体 tag, 否则下次跑永远判「同一来源」
	got_marker="$(cat "$REL_PREFIX/.node-source" 2>/dev/null)"
	[ "$got_marker" = "release:$BASELINE_TAG" ] ||
		fail "[01b] .node-source=$got_marker (expected release:$BASELINE_TAG)"
	[ -x "$REL_BIN/node" ] || fail "[01b] shim 未注册到独立 bin dir"
	ok "[01b] node 取自 release tarball ($REL_V), marker=$got_marker"

	# 二次运行必须走复用, 不再解包 (标记 + 可运行 = 复用条件)
	DSH_RUNTIME_DIR="$REL_PREFIX" DSH_BIN_DIR="$REL_BIN" \
		DSH_RELEASE="$BASELINE_TAG" DSH_RELEASE_TARBALL="$TARBALL" \
		bash "$TI_ROOT/../scripts/01-setup-glibc-node.sh" -y >"$ROOT/01c.log" 2>&1 ||
		{
			cat "$ROOT/01c.log"
			fail "[01c] rerun exited non-zero"
		}
	grep -q 'Reusing the Node already taken from release' "$ROOT/01c.log" ||
		fail "[01c] 二次运行没有复用已解包的 node"
	ok "[01b] 二次运行复用已解包的 node (无重复解包)"
else
	note "基线 tarball 不在场, 跳过 [01b] release 取 node 路径 (先跑 run.sh r2 或 baseline set 取资产)"
fi

echo "=== 2. [02] npm 装 dsh (--ignore-scripts; 冷装可能 20min+) ==="
bash "$TI_ROOT/../scripts/02-install-dsh.sh" -y >"$ROOT/02.log" 2>&1 ||
	{
		cat "$ROOT/02.log"
		fail "[02] exited non-zero"
	}
[ -f "$ROOT/prefix/work/node_modules/@deepseek-ai/dsh/lib/bin.js" ] ||
	fail "dsh not installed after [02]"
ok "[02] dsh 已从 npm 装入"

echo "=== 3. [03] dsh 树体检 + 补丁集 ==="
bash "$TI_ROOT/../scripts/03-apply-patches.sh" -y >"$ROOT/03.log" 2>&1 ||
	{
		cat "$ROOT/03.log"
		fail "[03] exited non-zero"
	}
# 体检段必须真的报出已装 dsh 版本与补丁库规模 (否则「检查」是空转)
grep -q 'dsh version' "$ROOT/03.log" || fail "[03] 体检段未输出 dsh 版本"
grep -q 'patch registry' "$ROOT/03.log" || fail "[03] 体检段未输出补丁库规模"
# 期望值不硬编码: source 工作区 patch-lib.sh, 按 DSH_PATCH_SET 全集验 marker
# (与 r4 同款派生逻辑; 新增/删除补丁时本路线自动跟随)。
# shellcheck source=../../scripts/patch-lib.sh
. "$TI_ROOT/../scripts/patch-lib.sh"
NPATCH=0
for entry in "${DSH_PATCH_SET[@]}"; do
	IFS=: read -r patch rel _ precondition _ <<<"$entry"
	# 条件条目 (四段式) 对不含该上游代码的 dsh 版本不适用, 见 patch-lib.sh
	if ! dsh_patch_applicable "$ROOT/prefix/work" "$entry"; then
		note "补丁不适用于该 dsh 版本, 跳过: $rel (无 '${precondition}')"
		continue
	fi
	NPATCH=$((NPATCH + 1))
	marker="$(dsh_patch_marker "$patch")" || fail "DSH_PATCH_SET 条目缺 marker 字段: $entry"
	grep -q "$marker" "$ROOT/prefix/work/node_modules/@deepseek-ai/$rel" ||
		fail "marker '$marker' missing in $rel (补丁未生效?)"
done
ok "[03] 适用补丁的标记齐全 ($NPATCH 个)"

echo "=== 4. [04] wrapper/opener/symlink + profile 启动 (启动答 n) ==="
printf 'n\n' | bash "$TI_ROOT/../scripts/04-launch.sh" --profile web >"$ROOT/04.log" 2>&1 ||
	{
		cat "$ROOT/04.log"
		fail "[04] exited non-zero"
	}
WRAP="$ROOT/prefix/work/dsh"
[ -x "$WRAP" ] || fail "wrapper missing after [04]"
WV="$(PATH="$ROOT/bin:$PATH" "$WRAP" --version 2>/dev/null | head -1)"
[ -n "$WV" ] || fail "dsh --version empty after [04]"
OPENER="$ROOT/prefix/work/dsh-termux-open"
[ -x "$OPENER" ] || fail "opener missing"
"$OPENER" </dev/null >/dev/null 2>&1
[ $? -eq 2 ] || fail "opener 无参退出码 != 2"
[ -L "$ROOT/bin/dsh" ] || fail "symlink missing"
[ "$(readlink "$ROOT/bin/dsh")" = "$WRAP" ] || fail "symlink target wrong"
grep -q 'dsh --profile web' "$ROOT/04.log" || fail "[04] 未按 profile 组装启动命令"
# bashrc 的 PATH 行现在由 [01] 写入; [04] 只断言它没被重复追加 (幂等)
NR="$(grep -c "export PATH=\"$ROOT/bin:\$PATH\"" "$ROOT/home/.bashrc")"
[ "$NR" = "1" ] || fail "bashrc PATH 行出现 $NR 次 (应为 1 次, 重复追加)"
ok "[04] wrapper/opener/symlink/profile 接线完成 ($WV)"

echo "=== 4b. 00-setup 的 runtime 自含段 (Option B 与 Option A 布局归一) ==="
# 00-setup.sh pipeline: 01→02→03→自含复制→04。r3 逐脚本驱动跳过了 00 的驱动
# 逻辑; 这里等价执行其复制段 (与 00-setup.sh 的 Bundling 块同源同序), 并断言
# 产物形态——Option B runtime 从此与 Option A release 布局一致, `dsh update`
# 的 wrapper 解析 (runtime 内置优先) 不再依赖 repo checkout 存活。
{
	mkdir -p "$ROOT/prefix/scripts"
	cp "$TI_ROOT/../scripts/update-dsh.sh" "$TI_ROOT/../scripts/common.sh" \
		"$TI_ROOT/../scripts/patch-lib.sh" "$ROOT/prefix/scripts/"
	rm -rf "$ROOT/prefix/patches"
	cp -r "$TI_ROOT/../patches" "$ROOT/prefix/patches"
	# 仓库项目 VERSION 已派生化: 以基线 pin 的稳定 release 尾段为准
	printf '%s\n' "${BASELINE_TAG##*-}" >"$ROOT/prefix/VERSION"
} >"$ROOT/00b.log" 2>&1 || {
	cat "$ROOT/00b.log"
	fail "自含复制段失败"
}
[ -f "$ROOT/prefix/scripts/update-dsh.sh" ] || fail "runtime 缺 scripts/update-dsh.sh"
[ -f "$ROOT/prefix/scripts/common.sh" ] || fail "runtime 缺 scripts/common.sh"
[ -f "$ROOT/prefix/scripts/patch-lib.sh" ] || fail "runtime 缺 scripts/patch-lib.sh"
[ -f "$ROOT/prefix/VERSION" ] || fail "runtime 缺 VERSION"
NSHIP="$(shipped_patch_entries "$ROOT/prefix/scripts/patch-lib.sh" | wc -l)"
[ "$NSHIP" -ge 1 ] || fail "runtime patches/ 未随 patch-lib 声明"
VSHIP="$(tr -d '[:space:]' <"$ROOT/prefix/VERSION")"
VREPO="${BASELINE_TAG##*-}"
[ "$VSHIP" = "$VREPO" ] || fail "runtime VERSION($VSHIP) != 派生的项目 VERSION($VREPO)"
ok "runtime 自含: scripts/ + patches/($NSHIP) + VERSION($VSHIP) 已入库 runtime"

echo "=== 5. 本地正在运行的 dsh runtime 未被触碰 ==="
live_sentinel

summary
