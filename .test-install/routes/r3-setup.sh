#!/data/data/com.termux/files/usr/bin/bash
# r3-setup.sh — R3 setup 管线测试: 驱动工作区 scripts/00-setup 流水线（拆步调用）。
# [01] 真机 pkg 前置 + nodejs.org 官方 node (版本取自仓库 config 的 node_version) + glibc
#      补丁 + node/npm shim 注册
#      -> [02] npm 装 @deepseek-ai/dsh (--ignore-scripts)
#      -> [03] dsh 树体检 + 补丁集 -> [04] wrapper/opener/symlink + profile 启动。
# 这是本项目**唯一**的安装路径: dsh 来自 npm registry, node 来自 nodejs.org,
# 补丁来自这个 checkout —— 没有预构建产物可装。
# 设备侧不下载本项目自己的 release 产物: node 只从 nodejs.org 取, 由本路线的
# 下载+sha256/GPG 验签+patchelf 断言覆盖。
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
# 01 会把装完的版本与 node 路径写回 config, 所以这里用沙箱内副本: 测试绝不改仓库里
# 那份受跟踪的 config。副本同时让「读 config」的断言有确定输入。
CFG="$ROOT/config"
cp "$TI_ROOT/../config" "$CFG" || fail "cannot stage config into the sandbox"
export DSH_CONFIG_FILE="$CFG"
export DSH_NODE_VERSION="24.19.0" # r3 自己钉死被测 node 版本 (仓库 config 的
# node_version 是 lts = active LTS 线, 会随上游换代而变; 测试要可复现, 所以这里
# 显式给精确版本, 并顺便覆盖「DSH_NODE_VERSION 优先于 config」这条优先级)。
# 这里取的是官方原版 (基线 tarball 里的 node 已打过补丁), 顺便验证 01 的下载+验签+
# patchelf 链路 —— 这也是设备侧唯一的 node 来源, 所以本节没有备选路径可退回。
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

# [01] 收尾把实情写回 config: node_version 是**输入**, 必须原样保留 (否则下次安装
# 就不再跟随 lts); node_installed_version / node_bin 记录磁盘上的现状。
[ -f "$CFG" ] || fail "[01] config 不见了: $CFG"
cfg_get() { sed -n "s/^$1=//p" "$CFG" | tail -1; }
[ "$(cfg_get node_version)" = "lts" ] ||
	fail "[01] 把输入 node_version 改成了 $(cfg_get node_version) (应为 lts)"
[ "$(cfg_get node_installed_version)" = "${NV#v}" ] ||
	fail "[01] config node_installed_version=$(cfg_get node_installed_version) (expected ${NV#v})"
[ "$(cfg_get node_bin)" = "$NODE" ] ||
	fail "[01] config node_bin=$(cfg_get node_bin) (expected $NODE)"
ok "[01] config 写回: node_version 未被动 + installed/bin 已记录"

echo "=== 1c. [01] env 未设时读 config 的 node_version, 版本已满足则复用 (不下载) ==="
sed -i "s/^node_version=.*/node_version=24.19.0/" "$CFG" ||
	fail "[01c] 无法改写沙箱 config"
env -u DSH_NODE_VERSION bash "$TI_ROOT/../scripts/01-setup-glibc-node.sh" -y >"$ROOT/01c.log" 2>&1 ||
	{
		cat "$ROOT/01c.log"
		fail "[01c] exited non-zero"
	}
grep -q "Node spec: 24.19.0 (from $CFG)" "$ROOT/01c.log" ||
	fail "[01c] 未从 config 读取 node_version (应打印 '(from $CFG)')"
grep -q 'already present' "$ROOT/01c.log" ||
	fail "[01c] 版本已满足却仍走了下载分支"
ok "[01c] config 生效: 读 24.19.0 + 复用已装 node"

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

echo "=== 4b. 00-setup 的 runtime 自含段 ==="
# 00-setup.sh pipeline: 01→02→03→自含复制→04。r3 逐脚本驱动跳过了 00 的驱动
# 逻辑; 这里等价执行其复制段 (与 00-setup.sh 的 Bundling 块同源同序), 并断言
# 产物形态——runtime 自带 updater + 补丁集, `dsh update` 的 wrapper 解析
# (runtime 内置优先) 不依赖 checkout 存活。
{
	mkdir -p "$ROOT/prefix/scripts"
	cp "$TI_ROOT/../scripts/update-dsh.sh" "$TI_ROOT/../scripts/common.sh" \
		"$TI_ROOT/../scripts/patch-lib.sh" "$ROOT/prefix/scripts/"
	rm -rf "$ROOT/prefix/patches"
	cp -r "$TI_ROOT/../patches" "$ROOT/prefix/patches"
} >"$ROOT/00b.log" 2>&1 || {
	cat "$ROOT/00b.log"
	fail "自含复制段失败"
}
[ -f "$ROOT/prefix/scripts/update-dsh.sh" ] || fail "runtime 缺 scripts/update-dsh.sh"
[ -f "$ROOT/prefix/scripts/common.sh" ] || fail "runtime 缺 scripts/common.sh"
[ -f "$ROOT/prefix/scripts/patch-lib.sh" ] || fail "runtime 缺 scripts/patch-lib.sh"
NSHIP="$(shipped_patch_entries "$ROOT/prefix/scripts/patch-lib.sh" | wc -l)"
[ "$NSHIP" -ge 1 ] || fail "runtime patches/ 未随 patch-lib 声明"
ok "runtime 自含: scripts/ + patches/($NSHIP) 已入库 runtime"

echo "=== 5. 本地正在运行的 dsh runtime 未被触碰 ==="
live_sentinel

summary
