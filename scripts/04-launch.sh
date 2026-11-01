#!/data/data/com.termux/files/usr/bin/bash
# 04-launch.sh — install the `dsh` command, then launch a dsh profile.
#
# Besides launching (default profile: web), this script:
#   - writes a `dsh` launcher wrapper into $WORK_DIR (execs the configured glibc
#     Node directly, accepting the same args as the real dsh CLI) plus the
#     `dsh-termux-open` Android-intent opener it points $BROWSER at — see
#     write_dsh_wrapper and write_dsh_opener in common.sh,
#   - symlinks it into $DSH_BIN_DIR (default $HOME/.local/bin).
#
# The bin dir's PATH line and the node/npm/npx(/pnpm) shims are 01's job (it
# owns the environment); this script only adds the dsh command to that dir.
#
# Profile mapping: the launcher always passes `--profile <name>`, the CLI's own
# top-level flag. For the web profile the host/port flags ride along, so
# `04-launch.sh` with no arguments behaves like the old `dsh web` invocation.
#
# Usage:
#   bash scripts/04-launch.sh                       # profile web on 127.0.0.1:3080
#   bash scripts/04-launch.sh --profile headless    # any other profile
#   bash scripts/04-launch.sh --port 8080 -- --dump-config
#                                                   # extra args go to dsh verbatim
#
# Flags:
#   --profile NAME   profile to launch (default $DSH_PROFILE, else web)
#   --host HOST      web only; default $HOST, else 127.0.0.1
#   --port PORT      web only; default $DSH_WEB_PORT, else 3080
#   -y, --yes        auto-accept prompts
#   --               pass every remaining argument to dsh untouched
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
NODE_BIN="$RUNTIME_DIR/node/bin/node"
WORK_DIR="${DSH_WORK_DIR:-$RUNTIME_DIR/work}"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"
PROFILE="${DSH_PROFILE:-web}"
HOST="${HOST:-127.0.0.1}"
PORT="${DSH_WEB_PORT:-${PORT:-3080}}"
EXTRA=()

while [ $# -gt 0 ]; do
	case "$1" in
	--profile)
		PROFILE="${2:-}"
		shift
		;;
	--profile=*) PROFILE="${1#*=}" ;;
	--host)
		HOST="${2:-}"
		shift
		;;
	--host=*) HOST="${1#*=}" ;;
	--port)
		PORT="${2:-}"
		shift
		;;
	--port=*) PORT="${1#*=}" ;;
	-y | --yes) DSH_ASSUME_YES=1 ;;
	-h | --help)
		sed -n '2,31p' "$0" >&2
		exit 0
		;;
	--)
		shift
		EXTRA+=("$@")
		break
		;;
	*) EXTRA+=("$1") ;;
	esac
	shift
done
export DSH_ASSUME_YES

[ -n "$PROFILE" ] || {
	echo "04-launch.sh: --profile needs a name" >&2
	exit 2
}
validate_port "$PORT" || {
	echo "04-launch.sh: --port must be 1..65535 (got '$PORT')" >&2
	exit 2
}

echo "==> [04] Preparing the dsh command + launching profile '${PROFILE}'"

if [ ! -x "$NODE_BIN" ]; then
	echo "!! glibc Node not found. Run: bash scripts/01-setup-glibc-node.sh" >&2
	exit 1
fi
if [ ! -d "$WORK_DIR/node_modules/@deepseek-ai" ]; then
	echo "!! dsh not installed. Run: bash scripts/02-install-dsh.sh" >&2
	exit 1
fi

# --- Configure Node for direct exec ----------------------------------------
# Existing installs predate the direct-exec wrapper; this is idempotent.
configure_glibc_node "$NODE_BIN"

# --- Generate the wrapper --------------------------------------------------
DSH_BIN="$WORK_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
WRAPPER="$WORK_DIR/dsh"

# `dsh update` shortcut target: prefer the updater bundled inside the runtime
# dir (Option A release installs), fall back to this repo copy (Option B, where
# scripts/ only exists in the checkout).
UPDATER="$RUNTIME_DIR/scripts/update-dsh.sh"
[ -f "$UPDATER" ] || UPDATER="$BASE_DIR/scripts/update-dsh.sh"

write_dsh_wrapper "$WRAPPER" "$NODE_BIN" "$DSH_BIN" "$UPDATER"
echo "    Wrapper written: $WRAPPER"
echo "    Opener written : $WORK_DIR/dsh-termux-open  (\$BROWSER for the web handoff)"

# --- Symlink into bin dir ---------------------------------------------------
mkdir -p "$BIN_DIR"
LINK="$BIN_DIR/dsh"
ln -sf "$WRAPPER" "$LINK"
echo "    Symlinked: $LINK -> $WRAPPER"
if ! grep -qF '# dsh-termux' "$HOME/.bashrc" 2>/dev/null; then
	echo "    NOTE: $BIN_DIR is not on PATH yet (01 normally adds it)."
	echo "          Run: bash scripts/01-setup-glibc-node.sh   — or call '$WRAPPER' directly."
fi

# --- Launch -----------------------------------------------------------------
# Launch through the wrapper so this run gets exactly what the `dsh` command
# gets: direct node exec (correct process.execPath) and the $BROWSER handoff.
LAUNCH=(--profile "$PROFILE")
if [ "$PROFILE" = "web" ]; then
	LAUNCH+=(--host "$HOST" --port "$PORT")
fi
if [ ${#EXTRA[@]} -gt 0 ]; then
	LAUNCH+=("${EXTRA[@]}")
fi

printf '    dsh %s\n' "${LAUNCH[*]}"
if ask_yes_no "Start dsh --profile ${PROFILE} now?"; then
	cd "$WORK_DIR"
	if [ "$PROFILE" = "web" ]; then
		echo "==> Starting dsh web at http://${HOST}:${PORT} ..."
		echo "    (Keep Termux in the foreground: Android blocks activity launches"
		echo "     from a background app, which would swallow the browser handoff.)"
	else
		echo "==> Starting dsh --profile ${PROFILE} ..."
	fi
	exec "$WRAPPER" "${LAUNCH[@]}"
fi
echo "==> [04] Done. Launch later with: bash scripts/04-launch.sh [--profile NAME]"
