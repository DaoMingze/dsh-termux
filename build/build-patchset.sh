#!/data/data/com.termux/files/usr/bin/bash
# build-patchset.sh — pack the patch set that this project publishes as its ONLY
# release asset (dsh-termux-patchset.tar.gz).
#
# This asset is the single thing a device ever downloads from this project's
# releases: glibc packages come from Termux, Node from nodejs.org, dsh from the
# npm registry, and the installer/updater scripts come from the checkout. What
# changes without a new dsh version is the PATCH SET — so that is what ships.
#
# Members (fixed; `dsh update --self` and `--patch-set` both depend on them):
#   scripts/update-dsh.sh
#   scripts/common.sh
#   scripts/patch-lib.sh
#   patches/*.patch
# No VERSION member: identity is the content signature printed at the end (see
# dsh_patch_set_signature in scripts/common.sh), so nothing can drift.
#
# help-begin
#
# Usage:
#   bash build/build-patchset.sh                       # repo root -> ./dsh-termux-patchset.tar.gz
#   bash build/build-patchset.sh -r <dir> -o <out>     # explicit source / output
#   bash build/build-patchset.sh --list                # print members, write nothing
#
# Flags:
#   -r, --root DIR   source root (default: the repo root; a runtime dir works too)
#   -o, --out FILE   output tarball (default: ./dsh-termux-patchset.tar.gz)
#   --list           print the members that would be packed, write nothing
#   -h, --help       show this help
# help-end
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/common.sh
source "$BASE_DIR/scripts/common.sh"

ROOT="$BASE_DIR"
OUT="dsh-termux-patchset.tar.gz"
LIST_ONLY=0

usage() {
	sed -n '/^# help-begin/,/^# help-end/{//!p;}' "$0" >&2
	exit 0
}
fail() {
	echo "!! build-patchset: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	-r | --root)
		[ $# -ge 2 ] || fail "--root needs a directory"
		ROOT="$2"
		shift
		;;
	-o | --out)
		[ $# -ge 2 ] || fail "--out needs a path"
		OUT="$2"
		shift
		;;
	--list) LIST_ONLY=1 ;;
	-h | --help) usage ;;
	*) fail "unknown option: $1 (try --help)" ;;
	esac
	shift
done

ROOT="$(cd "$ROOT" && pwd)" || fail "source root not found"
for f in scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh; do
	[ -f "$ROOT/$f" ] || fail "missing $f under $ROOT"
done
compgen -G "$ROOT/patches/*.patch" >/dev/null || fail "no patches/*.patch under $ROOT"

# Registry consistency — the same authority the apply step loads. Every declared
# patch file must be present; an unregistered patch file is packed too but noted
# (a local set may legitimately carry a work-in-progress patch).
entries="$(bash -c 'source "$1"; printf "%s\n" "${DSH_PATCH_SET[@]}"' _ "$ROOT/scripts/patch-lib.sh")" ||
	fail "cannot source $ROOT/scripts/patch-lib.sh"
[ -n "$entries" ] || fail "patch-lib.sh declares no DSH_PATCH_SET entries"
while IFS= read -r entry; do
	[ -n "$entry" ] || continue
	patch="${entry%%:*}"
	[ -f "$ROOT/patches/$patch" ] || fail "registry names a missing patch file: $patch"
done <<<"$entries"
for p in "$ROOT"/patches/*.patch; do
	base="$(basename "$p")"
	hit=0
	while IFS= read -r e; do
		[ "${e%%:*}" = "$base" ] && {
			hit=1
			break
		}
	done <<<"$entries"
	[ "$hit" = 1 ] || echo "    note: patch file not in DSH_PATCH_SET (still packed): $base"
done

if [ "$LIST_ONLY" = 1 ]; then
	printf '%s\n' scripts/update-dsh.sh scripts/common.sh scripts/patch-lib.sh
	for p in "$ROOT"/patches/*.patch; do printf 'patches/%s\n' "$(basename "$p")"; done
	exit 0
fi

# Stage the exact layout, then tar it: a checkout's scripts/ holds the whole
# setup pipeline, and only the three updater scripts belong in the asset.
tmp_root="${TMPDIR:-$HOME/.cache}/dsh-termux-patchset"
mkdir -p "$tmp_root"
stage="$(mktemp -d "$tmp_root/XXXXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/scripts"
cp "$ROOT/scripts/update-dsh.sh" "$ROOT/scripts/common.sh" "$ROOT/scripts/patch-lib.sh" "$stage/scripts/"
cp -r "$ROOT/patches" "$stage/patches"
tar -czf "$OUT" -C "$stage" scripts patches

sig="$(dsh_patch_set_signature "$stage")"
echo "==> packed $OUT"
tar -tzf "$OUT" | sed 's/^/    /'
ls -lh "$OUT" | awk '{print "    size: " $5}'
echo "    patch-set signature: $sig"
echo "    (devices holding this signature need no update; compare with:"
echo "     bash scripts/update-dsh.sh --self --dry-run)"
