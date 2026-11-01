#!/data/data/com.termux/files/usr/bin/bash
# 00-setup.sh — entry point: configure environment and drive the install
# pipeline (01 -> 02 -> 03 -> 04).
#
#   01  Termux prerequisites + glibc Node, registered as node/npm/npx(/pnpm)
#   02  dsh from npm (--ignore-scripts) + native-addon check (no fetch)
#   03  dsh tree check + the patches matching that dsh version
#   04  the `dsh` command, then launch a profile (default web)
#
# Usage:
#   bash scripts/00-setup.sh               # default values + asks
#   bash scripts/00-setup.sh --interaction # interactively set env values + asks
#   bash scripts/00-setup.sh -y            # default values, auto-accept all prompts
#   bash scripts/00-setup.sh --interaction -y   # interactive env, auto-accept installs
#
# Flags:
#   -y, --yes           auto-accept every prompt
#   --interaction       interactively set environment values (default: use defaults)
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

MODE="default" # default | interaction
DSH_ASSUME_YES=0

while [ $# -gt 0 ]; do
	case "${1,,}" in
	-y | --yes) DSH_ASSUME_YES=1 ;;
	--interaction | --interactive) MODE="interaction" ;;
	-h | --help)
		sed -n '2,18p' "$0" >&2
		exit 0
		;;
	*)
		echo "00-setup.sh: unknown option: $1" >&2
		echo "Usage: bash scripts/00-setup.sh [--interaction] [-y]" >&2
		exit 2
		;;
	esac
	shift
done

echo "==> dsh-termux installer"
echo "    mode: ${MODE}   assume-yes: ${DSH_ASSUME_YES}"

# --- Environment configuration --------------------------------------------
# Node 统一从 nodejs.org 取: 版本取值优先级 = $DSH_NODE_VERSION > 仓库 config 的
# node_version (=lts, 当前 active LTS 线) > "lts"。设备侧不下载本项目的 release
# 产物; 01 装完会把实际版本与 node 路径写回 config。
DEF_NODE_VERSION="${DSH_NODE_VERSION:-$(dsh_config_get node_version)}"
DEF_NODE_VERSION="${DEF_NODE_VERSION:-lts}"
DEF_RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
DEF_WORK_DIR="${DSH_WORK_DIR:-}"
DEF_PORT="${DSH_WEB_PORT:-3080}"
DEF_BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"
DEF_PROFILE="${DSH_PROFILE:-web}"

if [ "$MODE" = "interaction" ]; then
	echo
	echo "==> Configure environment (Enter accepts the default)"
	ask_input DSH_RUNTIME_DIR "Runtime dir (space-free absolute path)" \
		"$DEF_RUNTIME_DIR" validate_abs_path
	ask_input DSH_NODE_VERSION "Node spec (lts | 24 | X.Y.Z)" \
		"$DEF_NODE_VERSION" validate_node_version
	ask_input DSH_WORK_DIR "Work dir (empty = \$DSH_RUNTIME_DIR/work)" \
		"$DEF_WORK_DIR" validate_abs_path
	ask_input DSH_WEB_PORT "Default web port" "$DEF_PORT" validate_port
	ask_input DSH_BIN_DIR "Where to symlink the dsh command" \
		"$DEF_BIN_DIR" validate_abs_path
	ask_input DSH_PROFILE "Profile to launch (04's default)" \
		"$DEF_PROFILE" validate_profile_name
else
	DSH_RUNTIME_DIR="$DEF_RUNTIME_DIR"
	DSH_NODE_VERSION="$DEF_NODE_VERSION"
	DSH_WORK_DIR="$DEF_WORK_DIR"
	DSH_WEB_PORT="$DEF_PORT"
	DSH_BIN_DIR="$DEF_BIN_DIR"
	DSH_PROFILE="$DEF_PROFILE"
fi

# Normalize empty work dir to <runtime>/work.
DSH_WORK_DIR="${DSH_WORK_DIR:-$DSH_RUNTIME_DIR/work}"

# "lts" is a moving target; show what it currently resolves to rather than a
# keyword nobody can read. Network failure here is not fatal — 01 resolves
# again and reports the real error.
case "${DSH_NODE_VERSION,,}" in
lts*)
	echo "==> Resolving '${DSH_NODE_VERSION}' against nodejs.org ..."
	if RESOLVED="$(resolve_node_version "$DSH_NODE_VERSION" 2>/dev/null)"; then
		echo "    -> Node v${RESOLVED}"
	else
		echo "    -> (unresolved now; 01 will retry and report the failure)"
	fi
	;;
esac

export DSH_RUNTIME_DIR DSH_NODE_VERSION DSH_WORK_DIR DSH_WEB_PORT DSH_BIN_DIR DSH_PROFILE
export DSH_ASSUME_YES
echo "==> Using:"
echo "    DSH_RUNTIME_DIR = $DSH_RUNTIME_DIR"
echo "    DSH_NODE_VERSION = $DSH_NODE_VERSION"
echo "    DSH_WORK_DIR    = $DSH_WORK_DIR"
echo "    DSH_WEB_PORT    = $DSH_WEB_PORT"
echo "    DSH_BIN_DIR     = $DSH_BIN_DIR"
echo "    DSH_PROFILE     = $DSH_PROFILE"

# --- Pipeline --------------------------------------------------------------
if ! ask_yes_no "Proceed with installation?"; then
	echo "Aborted."
	exit 1
fi

bash "$BASE_DIR/scripts/01-setup-glibc-node.sh" || exit $?
bash "$BASE_DIR/scripts/02-install-dsh.sh" || exit $?
bash "$BASE_DIR/scripts/03-apply-patches.sh" || exit $?

# --- Make the runtime self-contained ----------------------------------------
# Copy the updater, its helper libs and the patch set INTO the runtime dir
# BEFORE 04 runs: the wrapper's `dsh update` shortcut then resolves the
# runtime-bundled copy (see 04-launch.sh and write_dsh_wrapper) and keeps
# working even if this checkout is later moved or deleted. `dsh update --self`
# applies that bundled set; re-running this script after `git pull` refreshes
# it from the checkout.
echo "==> Bundling updater + patches into the runtime dir"
mkdir -p "$DSH_RUNTIME_DIR/scripts"
cp "$BASE_DIR/scripts/update-dsh.sh" "$BASE_DIR/scripts/common.sh" \
	"$BASE_DIR/scripts/patch-lib.sh" "$DSH_RUNTIME_DIR/scripts/"
rm -rf "$DSH_RUNTIME_DIR/patches"
cp -r "$BASE_DIR/patches" "$DSH_RUNTIME_DIR/patches"
echo "    Updater bundled: $DSH_RUNTIME_DIR/scripts/update-dsh.sh"
echo "    Patch set:       $DSH_RUNTIME_DIR/patches ($(
	set -- "$DSH_RUNTIME_DIR"/patches/*.patch
	[ -e "$1" ] && echo "$#" || echo 0
) patches)"

bash "$BASE_DIR/scripts/04-launch.sh" || exit $?

echo
echo "==> Install complete."
echo "    Start dsh anytime with:      bash scripts/04-launch.sh [--profile NAME]"
echo "    (default profile: ${DSH_PROFILE:-web})"
echo "    Update dsh anytime with:     dsh update -t next -y"
