#!/data/data/com.termux/files/usr/bin/bash
# update-dsh.sh — update dsh to a chosen npm version and re-apply patches.
# help-begin
#
# This is the maintenance counterpart to 00-setup.sh. It:
#   1. queries the npm registry for available versions (dist-tags + full list),
#   2. installs the chosen version under the glibc Node (npm install <tag>),
#   3. re-applies the Android patch set (idempotent),
#   4. rewrites the `dsh` wrapper + symlink (including the Termux $BROWSER
#      handoff — see write_dsh_wrapper in common.sh) and refreshes the
#      node/npm/npx/pnpm shims (write_node_shims; no prompts on this path).
#
# The only thing this project publishes is the patch set
# (dsh-termux-patchset.tar.gz, ~40 KB): glibc/node/npm/dsh all come from their own
# upstreams, on the device. So the patch set is the one thing an update may
# download — and even that only when the content actually differs (identity is
# the content signature, not a version number).
#
# `--self` is the patches-only path: it fetches that asset, compares signatures
# and, when the runtime is behind, installs it and APPLIES it to the installed
# dsh — no npm download. `--patch-set PATH` takes the same set from a local
# directory or tarball instead (after `git pull`, for example), and
# `--dry-run` reports whether an update is available without applying it.
#
# It does NOT manage a running web instance; start/restart web yourself with
# `dsh web` (e.g. `dsh web --port 3080`). This keeps the updater side-effect free.
#
# Usage:
#   bash scripts/update-dsh.sh                # pick a version interactively
#   bash scripts/update-dsh.sh -y             # update to latest (auto-accept)
#   bash scripts/update-dsh.sh -v 0.1.0-rc.8  # update to a specific version (no menu)
#   bash scripts/update-dsh.sh -t next        # update to a dist-tag (no menu)
#   bash scripts/update-dsh.sh --self         # fetch the published patch set and
#                                             # apply it (no npm update)
#   bash scripts/update-dsh.sh --self --dry-run
#                                             # report whether one is available
#   bash scripts/update-dsh.sh --patch-set <dir|tar.gz>
#                                             # same, with the patch set taken from
#                                             # an explicit directory or tarball
#   bash scripts/update-dsh.sh --self --force # re-apply even when already current
#   bash scripts/update-dsh.sh -h             # show this help
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   -v, --version VER   exact version to install (skips the target menu)
#   -t, --tag TAG       npm dist-tag to install (skips the target menu)
#   --self              fetch the patch set this project publishes, install it as
#                       the runtime's copy and apply it to the installed dsh.
#                       Does NOT run the npm update (-t/-v are ignored here).
#   --patch-set PATH    take the patch set from PATH (a directory or .tar.gz with
#                       scripts/ + patches/) instead of downloading it. Implies
#                       --self.
#   --dry-run           with --self/--patch-set: report whether the runtime is
#                       behind and exit without changing anything.
#   --force             with --self/--patch-set: re-apply even when the content
#                       is already current.
#   -h, --help          show this help
# help-end
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"
source "$BASE_DIR/scripts/patch-lib.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
NODE_BIN="$RUNTIME_DIR/node/bin/node"
NPM_CLI="$RUNTIME_DIR/node/lib/node_modules/npm/bin/npm-cli.js"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
PATCHES="$BASE_DIR/patches"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"
REPO="${DSH_REPO:-ErEbusE/dsh-termux}" # publishes the patch set; nothing else
SELF_DIR="$RUNTIME_DIR"                # where --self installs its copy of scripts/ + patches/

# Same npm-heap guard as 02-install-dsh.sh: npm's arborist OOMs at the ~2GB
# default V8 heap when resolving dsh's ~60-dependency tree on arm64.
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096"

DSH_ASSUME_YES=0
SPEC=""
TAG=""
SELF=0
PATCH_SET=""
FORCE=0
DRY_RUN=0

# The help text is the block between the '# help-begin' / '# help-end' markers
# in the header above — derived, never a hardcoded line range. CI asserts that
# what this prints and what the markers delimit are the same text.
usage() {
	sed -n '/^# help-begin/,/^# help-end/{//!p;}' "$0" >&2
	exit 0
}

while [ $# -gt 0 ]; do
	case "${1,,}" in
	-y | --yes) DSH_ASSUME_YES=1 ;;
	-v | --version)
		SPEC="$2"
		shift
		;;
	-t | --tag)
		TAG="$2"
		shift
		;;
	--self) SELF=1 ;;
	--patch-set)
		[ $# -ge 2 ] || {
			echo "update-dsh.sh: --patch-set needs a path" >&2
			usage
		}
		PATCH_SET="$2"
		shift
		;;
	--dry-run | --dryrun) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	-h | --help) usage ;;
	*)
		echo "update-dsh.sh: unknown option: $1" >&2
		usage
		;;
	esac
	shift
done

# --patch-set is the same operation as --self, only with an explicit source;
# --dry-run only means something for that operation.
[ -z "$PATCH_SET" ] || SELF=1
if [ "$FORCE" = 1 ] && [ "$SELF" != 1 ]; then
	echo "update-dsh.sh: note: --force only applies to --self/--patch-set; ignoring it." >&2
	FORCE=0
fi
if [ "$DRY_RUN" = 1 ] && [ "$SELF" != 1 ]; then
	echo "update-dsh.sh: note: --dry-run only applies to --self/--patch-set; ignoring it." >&2
	DRY_RUN=0
fi

# --- The local patch set ---------------------------------------------------
# A patch set is a directory holding the three shared scripts and patches/*.
# The default source is the directory this script lives in: run from a checkout
# right after `git pull`, that is the newest set; run as the runtime's bundled
# copy, it is the set 00-setup installed. --patch-set points somewhere else.
# patch_set_validate <dir>
# Assert <dir> holds the layout every consumer expects — scripts/{update-dsh,
# common,patch-lib}.sh + patches/*.patch — and that its registry names only
# patch files present. Extra files are allowed (a repo checkout is a valid
# source); an unregistered patch file is a note, not a failure.
patch_set_validate() {
	local dir="$1" f missing=0
	for f in scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh; do
		[ -f "$dir/$f" ] || {
			echo "!! patch set is missing $f: $dir" >&2
			missing=1
		}
	done
	if [ ! -d "$dir/patches" ] || ! compgen -G "$dir/patches/*.patch" >/dev/null; then
		echo "!! patch set has no patches/*.patch: $dir" >&2
		missing=1
	fi
	[ "$missing" = 0 ] || return 1

	# The set's own patch-lib.sh is the registry authority (the same file the
	# apply step will load), so source it in a subshell.
	local entries entry patch p base hit e
	if ! entries="$(bash -c 'source "$1"; printf "%s\n" "${DSH_PATCH_SET[@]}"' _ "$dir/scripts/patch-lib.sh" 2>/dev/null)"; then
		echo "!! patch set patch-lib.sh could not be sourced: $dir/scripts/patch-lib.sh" >&2
		return 1
	fi
	[ -n "$entries" ] || {
		echo "!! patch set declares no DSH_PATCH_SET entries: $dir" >&2
		return 1
	}
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		patch="${entry%%:*}"
		[ -f "$dir/patches/$patch" ] || {
			echo "!! patch set registry names a missing patch file: $patch" >&2
			missing=1
		}
	done <<<"$entries"
	for p in "$dir"/patches/*.patch; do
		[ -f "$p" ] || continue
		base="$(basename "$p")"
		hit=0
		while IFS= read -r e; do
			[ "${e%%:*}" = "$base" ] && {
				hit=1
				break
			}
		done <<<"$entries"
		[ "$hit" = 1 ] || echo "    note: patch file not in DSH_PATCH_SET (ignored): $base"
	done
	[ "$missing" = 0 ]
}

# stage_patch_set <source> <dest>
# Materialize <source> (directory or .tar.gz) into <dest>. Validation is the
# caller's step, so every source runs through the same checks.
stage_patch_set() {
	local src="$1" dest="$2"
	if [ -d "$src" ]; then
		mkdir -p "$dest"
		cp -r "$src/scripts" "$src/patches" "$dest/" 2>/dev/null || true
	elif [ -f "$src" ]; then
		mkdir -p "$dest"
		if ! tar -xzf "$src" -C "$dest" scripts patches 2>/dev/null; then
			echo "!! --patch-set: $src is not a patch-set tarball" >&2
			echo "   (want scripts/{update-dsh,common,patch-lib}.sh + patches/)" >&2
			return 1
		fi
	else
		echo "!! --patch-set: no such file or directory: $src" >&2
		return 1
	fi
}

# apply_patch_set_only <patches_dir> [old_set_dir]
# Apply the patch set in <patches_dir> to the installed tree using the registry
# $SELF_DIR's copies carry, then rewrite the wrapper. When <old_set_dir> holds
# a pre-refresh snapshot (registry.sh + patches/), those patches are reversed
# FIRST with their own bytes: without a reinstall a dropped or rewritten patch
# would otherwise linger, or fail the forward apply as version drift.
apply_patch_set_only() {
	local patches_dir="$1" old_set="$2"
	if [ -n "$old_set" ] && [ -f "$old_set/registry.sh" ]; then
		echo "==> [self] Reversing the previously applied patch set"
		(
			. "$old_set/registry.sh"
			dsh_reverse_patch_set "$WORK_DIR" "$old_set/patches"
		) || {
			echo "!! --self: could not reverse the previous patch set; aborting before applying the new one." >&2
			return 1
		}
	fi
	echo "==> [self] Applying the local patch set"
	dsh_apply_patch_set "$WORK_DIR" "$patches_dir" || return 1

	local dsh_bin="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
	local wrapper="$WORK_DIR/dsh" updater="$RUNTIME_DIR/scripts/update-dsh.sh"
	[ -f "$updater" ] || updater="$BASE_DIR/scripts/update-dsh.sh"
	write_dsh_wrapper "$wrapper" "$NODE_BIN" "$dsh_bin" "$updater"
	mkdir -p "$BIN_DIR"
	ln -sf "$wrapper" "$BIN_DIR/dsh"
	echo "==> [self] Wrapper updated: $BIN_DIR/dsh -> $wrapper"
}

# self_update — the --self/--patch-set body: take the patch set, install it as
# the runtime's own copy, apply it to the installed dsh, stop. Never touches npm.
self_update() {
	local src work stage old_sig new_sig old_set_dir="" npatches=0 p pkg

	if [ ! -x "$NODE_BIN" ]; then
		echo "!! glibc Node not found. Run: bash scripts/00-setup.sh" >&2
		exit 1
	fi
	if [ ! -d "$WORK_DIR/node_modules/@deepseek-ai/dsh" ]; then
		echo "!! dsh not installed yet. Run: bash scripts/00-setup.sh" >&2
		exit 1
	fi
	configure_glibc_node "$NODE_BIN"

	work="$(mktemp -d "${TMPDIR:-$HOME/.cache}/dsh-termux-self.XXXXXXXX")" || exit 1
	stage="$work/set"
	mkdir -p "$stage"

	if [ -n "$PATCH_SET" ]; then
		src="$PATCH_SET"
		echo "==> [self] Local patch set: $src"
		if ! stage_patch_set "$src" "$stage"; then
			rm -rf "$work"
			exit 1
		fi
	else
		# The one thing this project publishes. ~40 KB, gzip-checked, atomic.
		pkg="$work/dsh-termux-patchset.tar.gz"
		echo "==> [self] Fetching the published patch set from $REPO ..."
		if ! dsh_fetch --gzip --max-time 120 \
			"https://github.com/$REPO/releases/latest/download/dsh-termux-patchset.tar.gz" "$pkg" ||
			! tar -xzf "$pkg" -C "$stage" scripts patches; then
			echo "!! --self: cannot get the published patch set." >&2
			echo "   Offline, or nothing has been published yet. A local set works too:" >&2
			echo "     dsh update --self --patch-set <dir|tar.gz>" >&2
			rm -rf "$work"
			exit 1
		fi
	fi
	if ! patch_set_validate "$stage"; then
		rm -rf "$work"
		exit 1
	fi

	old_sig="$(dsh_patch_set_signature "$SELF_DIR")"
	new_sig="$(dsh_patch_set_signature "$stage")"
	echo "    runtime patch-set: ${old_sig:-none}"
	echo "    offered patch-set: $new_sig"
	if [ "$old_sig" = "$new_sig" ] && [ "$FORCE" != 1 ]; then
		echo "==> [self] already current: the runtime carries this patch set."
		if [ "$DRY_RUN" != 1 ]; then
			echo "    Use --force to re-apply it anyway."
		fi
		rm -rf "$work"
		exit 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		echo "==> [self] update available: the runtime is behind this patch set."
		echo "    Apply it with: dsh update --self"
		rm -rf "$work"
		exit 0
	fi

	# Snapshot the runtime's current patch set BEFORE replacing it: the apply
	# step must take the old patches back with the OLD bytes (see
	# dsh_reverse_patch_set). A runtime from before this feature has none, and
	# the apply step then falls back to per-patch reverse with the new bytes.
	if [ -f "$SELF_DIR/scripts/patch-lib.sh" ] && [ -d "$SELF_DIR/patches" ]; then
		old_set_dir="$work/old"
		mkdir -p "$old_set_dir/patches"
		sed -n '/^DSH_PATCH_SET=(/,/^)/p' "$SELF_DIR/scripts/patch-lib.sh" >"$old_set_dir/registry.sh"
		cp "$SELF_DIR"/patches/*.patch "$old_set_dir/patches/" 2>/dev/null || true
	fi

	mkdir -p "$SELF_DIR/scripts"
	cp "$stage/scripts/update-dsh.sh" "$stage/scripts/common.sh" \
		"$stage/scripts/patch-lib.sh" "$SELF_DIR/scripts/"
	rm -rf "$SELF_DIR/patches"
	cp -r "$stage/patches" "$SELF_DIR/patches"
	for p in "$SELF_DIR"/patches/*.patch; do
		[ -f "$p" ] || continue
		npatches=$((npatches + 1))
	done
	echo "    runtime now carries scripts/ + patches/ ($npatches patches)"

	# Apply with the copies just installed, not the ones this process loaded at
	# startup: the set that lands on the tree must be the set the runtime keeps.
	if ! (
		. "$SELF_DIR/scripts/common.sh"
		. "$SELF_DIR/scripts/patch-lib.sh"
		apply_patch_set_only "$SELF_DIR/patches" "$old_set_dir"
	); then
		echo "!! --self: applying the patch set failed." >&2
		rm -rf "$work"
		exit 1
	fi
	rm -rf "$work"

	if [ -n "$SPEC" ] || [ -n "$TAG" ]; then
		echo "==> [self] NOTE: --self applies the patch set only; -t/-v are ignored." >&2
		echo "    To update the dsh version too, run: dsh update -t <tag>" >&2
	fi
	echo "==> [self] Done. Patch set applied; the dsh version is unchanged."
	echo "    To update the dsh version too:  dsh update"
	exit 0
}

if [ "$SELF" = "1" ]; then
	self_update
fi

# --- Preflight --------------------------------------------------------------
if [ ! -x "$NODE_BIN" ]; then
	echo "!! glibc Node not found. Run: bash scripts/00-setup.sh" >&2
	exit 1
fi
if [ ! -d "$WORK_DIR/node_modules/@deepseek-ai/dsh" ]; then
	echo "!! dsh not installed yet. Run: bash scripts/00-setup.sh" >&2
	exit 1
fi

# An install made before the direct-exec change still has a pristine node.
configure_glibc_node "$NODE_BIN"

echo "==> [update] dsh updater"
echo "    assume-yes: ${DSH_ASSUME_YES}"

# --- Query available versions ----------------------------------------------
echo "==> Querying npm registry for @deepseek-ai/dsh ..."
DIST_TAGS="$(run_glibc_node "$NODE_BIN" "$NPM_CLI" view @deepseek-ai/dsh dist-tags 2>/dev/null || true)"
CURRENT="$(run_glibc_node "$NODE_BIN" --expose-internals "$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" --version 2>/dev/null | tr -d '\r' || echo unknown)"

echo "    currently installed: $CURRENT"
echo "    registry dist-tags:"
echo "      $DIST_TAGS" | sed 's/^/      /'

# --- Decide target ----------------------------------------------------------
# IMPORTANT: resolve_target's stdout IS the result (TARGET="$(resolve_target)").
# All menu/prompt output must therefore go to stderr (>&2), and `read` must
# use `-p` (which also prints to stderr). Echoing prompts to stdout here would
# capture the whole menu INTO $TARGET and hand it to npm as a package spec —
# that is exactly the "Invalid tag name "=" of package "="" crash.
resolve_target() {
	if [ -n "$SPEC" ]; then
		echo "@deepseek-ai/dsh@$SPEC"
		return
	fi
	# -t picks a dist-tag directly (no menu), like -v picks a version.
	if [ -n "$TAG" ]; then
		echo "@deepseek-ai/dsh@$TAG"
		return
	fi
	local t="latest"
	if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
		echo "@deepseek-ai/dsh@$t"
		return
	fi
	echo "    Select a target (Enter = $t):" >&2
	local idx=1 choice
	local tags
	tags="$(echo "$DIST_TAGS" | tr -d '{}' | tr ',' '\n' | sed 's/^ *//;s/ *$//')"
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		local k="${line%%:*}"
		local v="${line##*:}"
		echo "      [$idx] tag $k -> $v" >&2
		idx=$((idx + 1))
	done <<<"$tags"
	echo "      [0] exact version" >&2
	read -r -p "    Choice [1-$((idx - 1)), 0=version, Enter=$t]: " choice
	choice="${choice:-1}"
	if [ "$choice" = "0" ]; then
		read -r -p "    Enter exact version (e.g. 0.1.0-rc.8): " SPEC
		echo "@deepseek-ai/dsh@$SPEC"
		return
	fi
	local n=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		n=$((n + 1))
		if [ "$n" = "$choice" ]; then
			local k="${line%%:*}"
			echo "@deepseek-ai/dsh@$k"
			return
		fi
	done <<<"$tags"
	echo "@deepseek-ai/dsh@$t"
}

TARGET="$(resolve_target)"
echo "==> Target: $TARGET"

# --- Install ----------------------------------------------------------------
cd "$WORK_DIR"
echo "==> Installing $TARGET (--ignore-scripts) ..."
if ! ask_yes_no "Update dsh to $TARGET?"; then
	echo "Aborted."
	exit 1
fi
run_glibc_node "$NODE_BIN" "$NPM_CLI" install "$TARGET" --ignore-scripts

# --- Native addons: check, never fetch ----------------------------------------
# --ignore-scripts means nothing is compiled here, and nothing needs to be:
# dsh >= 0.1.5 ships no dependency that needs building (fs-ext left the tree
# upstream, see PATCHES.md). A version pinned below that still expects
# fs_ext.node, which a phone cannot produce — fail with the reason rather than
# let dsh die at boot with "Cannot find module './build/Release/fs_ext.node'".
echo "==> Verifying native addons"
verify_native_prebuilds "$WORK_DIR" "$NODE_BIN" ||
	{
		echo "!! this dsh needs a compiled native addon that a device cannot build." >&2
		echo "   Point config's npm_version at >= 0.1.5, or install an older dsh" >&2
		echo "   from a machine that can compile it." >&2
		exit 1
	}

# --- Re-apply patches (verify against the freshly installed libs) -----------
# npm incremental installs may reuse the previously patched cache, so we cannot
# trust a leftover marker. dsh_apply_patch_set therefore reverse-applies any
# existing patch (restoring the pristine npm file), then forward-applies and
# verifies. If that fails, the patch does not match the installed version and
# must be regenerated (see PATCHES.md).
echo "==> [update] Re-applying Android hard-link patches"
if ! dsh_apply_patch_set "$WORK_DIR" "$PATCHES"; then
	echo "!! Patches do not apply to $TARGET." >&2
	echo "   dsh is installed but session saves and the write tool will fail on" >&2
	echo "   Android until the patches are regenerated — see PATCHES.md." >&2
	exit 1
fi

# --- Rewrite wrapper + symlink ----------------------------------------------
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
WRAPPER="$WORK_DIR/dsh"
# Re-bake the `dsh update` shortcut with the same resolution as 04-launch.sh:
# runtime-bundled updater first, repo checkout as fallback.
UPDATER="$RUNTIME_DIR/scripts/update-dsh.sh"
[ -f "$UPDATER" ] || UPDATER="$BASE_DIR/scripts/update-dsh.sh"
write_dsh_wrapper "$WRAPPER" "$NODE_BIN" "$DSH_BIN" "$UPDATER"
mkdir -p "$BIN_DIR"
ln -sf "$WRAPPER" "$BIN_DIR/dsh"
echo "==> Wrapper updated: $BIN_DIR/dsh -> $WRAPPER"

# --- Refresh node/npm/npx/pnpm shims -----------------------------------------
# Write-only on purpose: the Termux pkg conflict was an install-time decision
# (register_node_shims). Non-fatal: dsh itself is done.
if ! write_node_shims "$BIN_DIR" "$RUNTIME_DIR/node"; then
	echo "!! node/npm/npx/pnpm shims not refreshed (see message above); dsh is unaffected." >&2
fi

NEW_VERSION="$(run_glibc_node "$NODE_BIN" --expose-internals "$DSH_BIN" --version 2>/dev/null | tr -d '\r')"
echo "==> Updated to: $NEW_VERSION"

echo "==> [update] Done. dsh is now $NEW_VERSION (was $CURRENT)."
echo "    Start the web UI yourself, e.g.:  dsh web --port ${DSH_WEB_PORT:-3080}"
