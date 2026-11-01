#!/data/data/com.termux/files/usr/bin/bash
# 03-apply-patches.sh — check the installed dsh tree, then apply the patches
# from the registry that actually match this dsh version.
#
# The patch set lives in scripts/patch-lib.sh (DSH_PATCH_SET). Each entry is
# "<patch file>:<rel target>:<marker>[:<precondition>]" and applies to the
# COMPILED lib files inside node_modules (npm packages ship built JS).
#
# Step 1 inventories the tree against the registry, so a mismatch is reported
# as a mismatch instead of as a git-apply error three levels down:
#   - the dsh version actually installed, and how many @deepseek-ai packages
#     are present (dsh's first-party libs; the patch targets all live there);
#   - per entry: target present? / marker already baked in? / applicable?
# A MANDATORY entry (3 fields) whose target file is missing is fatal: the
# registry says that code must be there, so the tree is incomplete or the dsh
# version moved. A CONDITIONAL entry (4 fields) with a missing target is just
# inapplicable — its upstream code is not in this dsh release.
#
# Step 2 applies the selected entries and verifies every marker
# (dsh_apply_patch_set is idempotent and fails loudly on version drift).
#
# Flags:
#   -y, --yes   auto-accept prompts
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"
source "$BASE_DIR/scripts/patch-lib.sh"

for a in "$@"; do
	case "${a,,}" in
	-y | --yes) DSH_ASSUME_YES=1 ;;
	-h | --help)
		sed -n '2,25p' "$0" >&2
		exit 0
		;;
	*)
		echo "03-apply-patches.sh: unknown option: $a" >&2
		echo "Usage: bash scripts/03-apply-patches.sh [-y]" >&2
		exit 2
		;;
	esac
done
export DSH_ASSUME_YES

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
PATCHES="$BASE_DIR/patches"

echo "==> [03] Checking the installed dsh tree against the patch registry"

if [ ! -d "$WORK_DIR/node_modules" ]; then
	echo "!! No node_modules found in $WORK_DIR. Run: bash scripts/02-install-dsh.sh" >&2
	exit 1
fi

DSH_PKG_DIR="$WORK_DIR/node_modules/@deepseek-ai/dsh"
if [ ! -f "$DSH_PKG_DIR/package.json" ]; then
	echo "!! dsh is not installed in $WORK_DIR. Run: bash scripts/02-install-dsh.sh" >&2
	exit 1
fi
DSH_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
	"$DSH_PKG_DIR/package.json" | head -1)"
[ -n "$DSH_VER" ] || {
	echo "!! installed dsh version unreadable" >&2
	exit 1
}
SCOPE_COUNT="$(ls -1 "$WORK_DIR/node_modules/@deepseek-ai" 2>/dev/null | wc -l | tr -d '[:space:]')"
echo "    dsh version            : $DSH_VER"
echo "    @deepseek-ai packages  : $SCOPE_COUNT installed"
echo "    patch registry         : ${#DSH_PATCH_SET[@]} entries ($PATCHES)"
echo

# --- 1. Inventory ----------------------------------------------------------
selected=()
already=()
skipped=()
fatal=0

printf '    %-46s %s\n' "PATCH TARGET" "STATE"
for entry in "${DSH_PATCH_SET[@]}"; do
	IFS=: read -r patch rel marker precondition _ <<<"$entry"
	target="$WORK_DIR/node_modules/@deepseek-ai/$rel"
	# 前置条件字符串很长 (一行上游代码), 只留够辨认的前半段
	pre_short="$precondition"
	if [ ${#pre_short} -gt 30 ]; then pre_short="${pre_short:0:27}..."; fi

	if [ ! -f "$target" ]; then
		if [ -n "$precondition" ]; then
			# Conditional: the upstream code this patch edits is not in this release.
			printf '    %-46s %s\n' "$rel" "SKIP · conditional, target absent"
			skipped+=("$patch")
		else
			printf '    %-46s %s\n' "$rel" "MISSING · mandatory entry"
			fatal=1
		fi
		continue
	fi
	if ! dsh_patch_applicable "$WORK_DIR" "$entry"; then
		printf '    %-46s %s\n' "$rel" "SKIP · no '${pre_short}'"
		skipped+=("$patch")
		continue
	fi
	if grep -qF "$marker" "$target" 2>/dev/null; then
		printf '    %-46s %s\n' "$rel" "already patched"
		already+=("$patch")
	else
		printf '    %-46s %s\n' "$rel" "to patch"
	fi
	selected+=("$patch")
done
echo

if [ "$fatal" -eq 1 ]; then
	echo "!! A mandatory patch target is missing from this dsh tree." >&2
	echo "   Either 02 did not finish (npm install incomplete) or dsh changed its" >&2
	echo "   package layout — regenerate the patch set (see PATCHES.md)." >&2
	echo "   Nothing was applied." >&2
	exit 1
fi

echo "    applicable: ${#selected[@]}  (marker already present: ${#already[@]})  skipped: ${#skipped[@]}"
if [ ${#selected[@]} -eq 0 ]; then
	echo "==> [03] No applicable patches for dsh $DSH_VER. Nothing to do."
	echo "==> [03] Done. Next: scripts/04-launch.sh"
	exit 0
fi

# --- 2. Apply --------------------------------------------------------------
if ask_yes_no "Apply the ${#selected[@]} applicable Android patches?"; then
	# dsh_apply_patch_set is idempotent and fails loudly on version drift or when
	# git apply skips a patch instead of applying it (see scripts/patch-lib.sh).
	if ! dsh_apply_patch_set "$WORK_DIR" "$PATCHES"; then
		echo "!! Patching failed. dsh would misbehave on Android without these fixes" >&2
		echo "   (session saves, the write tool, sandboxed temp writes); see PATCHES.md" >&2
		echo "   to regenerate the failing patch." >&2
		exit 1
	fi
else
	echo "    Skipped (note: patched behaviors may fail on Android)."
fi

echo "==> [03] Done. Next: scripts/04-launch.sh"
