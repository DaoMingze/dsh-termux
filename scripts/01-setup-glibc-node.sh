#!/data/data/com.termux/files/usr/bin/bash
# 01-setup-glibc-node.sh — Termux prerequisites + the glibc Node the runtime
# runs on, and the node/npm/npx(/pnpm) commands that point at it.
#
# Steps:
#   1. Detect Termux ($PREFIX).
#   2. pkg prerequisites, installed in dependency order because the order is
#      not free: glibc-repo (the repository definition) must be installed AND
#      indexed before glibc / glibc-runner can resolve from it; gnupg (release
#      signature) and patchelf (ELF interpreter rewrite) come from the main
#      repo. Missing ones are listed and asked about first.
#   3. Decide which Node: DSH_NODE_VERSION, else the repo config's
#      node_version, else "lts" — the ACTIVE LTS line. The build comes from nodejs.org and from nowhere else: this step
#      never downloads this project's own release artifacts.
#   4. Fetch it: sha256 always, plus the signed manifest when gpg is available
#      (--insecure skips the signature half). A tarball is REUSED when its
#      sha256 matches, a partial one is RESUMED (curl -C -), and a file that
#      still fails verification is re-downloaded from scratch exactly once.
#   5. Extract node/ into the runtime dir, then write the version and the node
#      path back to the config so later runs need not re-probe the runtime.
#   6. Point its ELF interpreter at Termux's glibc loader so it can be exec'd
#      directly — see configure_glibc_node in common.sh for why grun's
#      `ld.so <node>` indirection breaks dsh.
#   7. Offer to uninstall a pkg-installed node stack (nodejs / nodejs-lts /
#      npm / pnpm): they provide their own bionic node/npm and would shadow
#      the glibc commands. Default is to keep them.
#   8. Register node/npm/npx (+pnpm when the runtime bundles it) as shims in
#      $DSH_BIN_DIR and put that directory on PATH in ~/.bashrc, so `node`
#      and `npm` resolve to the glibc build in a new shell.
#
# Env (all optional):
#   DSH_NODE_VERSION    lts | 24 | 24.19.0 — default: the repo config's
#                       node_version, else "lts" (the active LTS line)
#
# Flags (only meaningful when run directly; 00-setup.sh calls it bare):
#   -y, --yes   auto-accept every prompt
#   --insecure  skip the GPG signature check
#   --clean     delete downloads left in <runtime>/downloads/ after success
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

INSECURE=0
CLEAN=0
for a in "$@"; do
	case "${a,,}" in
	-y | --yes) DSH_ASSUME_YES=1 ;;
	--insecure) INSECURE=1 ;;
	--clean) CLEAN=1 ;;
	-h | --help)
		sed -n '2,39p' "$0" >&2
		exit 0
		;;
	*)
		echo "01-setup-glibc-node.sh: unknown option: $a" >&2
		echo "Usage: bash scripts/01-setup-glibc-node.sh [-y] [--insecure] [--clean]" >&2
		exit 2
		;;
	esac
done
export DSH_ASSUME_YES

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"
NODE_ROOT="$RUNTIME_DIR/node"
NODE_BIN="$NODE_ROOT/bin/node"

echo "==> [01] Environment check"

# --- 1. Termux detection ---------------------------------------------------
if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
	echo "!! Not a Termux environment (\$PREFIX unset or missing). Aborting." >&2
	exit 1
fi
echo "    Termux detected: PREFIX=$PREFIX"

# --- 2. pkg prerequisites --------------------------------------------------
# Each requirement is tested BOTH ways when they differ: the dpkg package for
# the two that the glibc repo provides, and the BINARY for patchelf/gnupg —
# glibc-runner ships its own patchelf, so "no dpkg patchelf" must not turn into
# a pointless install of a second copy.
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
have_patchelf() { command -v patchelf >/dev/null 2>&1; }
have_gpg() { command -v gpg >/dev/null 2>&1; }
have_grun() { command -v grun >/dev/null 2>&1; }

missing=()
pkg_installed glibc-repo || missing+=("glibc-repo")
pkg_installed glibc || missing+=("glibc")
have_grun || missing+=("glibc-runner")
# gnupg only matters for the signature check; --insecure waives both.
[ "$INSECURE" -eq 1 ] || have_gpg || missing+=("gnupg")
have_patchelf || missing+=("patchelf")

if [ ${#missing[@]} -gt 0 ]; then
	echo "    Missing pkg prerequisites: ${missing[*]}"
	if ! ask_yes_no "Install them now?"; then
		echo "!! These packages are required. Aborting." >&2
		exit 1
	fi

	# glibc-repo first: it only adds a repository, and the glibc packages below
	# live in it. `pkg update` refreshes the index so they resolve immediately
	# instead of failing as "package not found" on a stale index.
	if [[ " ${missing[*]} " == *" glibc-repo "* ]]; then
		echo "==> Adding the glibc repository (pkg install glibc-repo) ..."
		pkg install -y glibc-repo
		echo "==> Refreshing the package index (pkg update) ..."
		pkg update -y || echo "!! pkg update failed; continuing — the glibc install below may still resolve" >&2
	fi

	glibc_pkgs=()
	for p in glibc glibc-runner; do
		[[ " ${missing[*]} " == *" $p "* ]] && glibc_pkgs+=("$p")
	done
	if [ ${#glibc_pkgs[@]} -gt 0 ]; then
		echo "==> Installing ${glibc_pkgs[*]} ..."
		pkg install -y "${glibc_pkgs[@]}"
	fi

	tool_pkgs=()
	for p in gnupg patchelf; do
		[[ " ${missing[*]} " == *" $p "* ]] && tool_pkgs+=("$p")
	done
	if [ ${#tool_pkgs[@]} -gt 0 ]; then
		echo "==> Installing ${tool_pkgs[*]} ..."
		pkg install -y "${tool_pkgs[@]}"
	fi
fi

# --- 2b. Re-check: a silent miss here surfaces later as a confusing failure
pkg_installed glibc-repo || {
	echo "!! pkg package 'glibc-repo' still missing after install. Aborting." >&2
	exit 1
}
pkg_installed glibc || {
	echo "!! pkg package 'glibc' still missing after install. Aborting." >&2
	exit 1
}
have_grun || {
	echo "!! glibc-runner (grun) still missing after install. Aborting." >&2
	exit 1
}
have_patchelf || {
	echo "!! patchelf still missing after install. Aborting." >&2
	exit 1
}
if [ "$INSECURE" -eq 0 ]; then
	have_gpg || {
		echo "!! gnupg (gpg) still missing. Either install it (pkg install gnupg) or" >&2
		echo "   re-run with --insecure to skip the signature check." >&2
		exit 1
	}
	echo "    gpg      OK: $(command -v gpg)"
fi
echo "    grun     OK: $(command -v grun)"
echo "    patchelf OK: $(command -v patchelf)"

# --- 3. Which Node, and where it comes from --------------------------------
# The Node comes from nodejs.org and from nowhere else. Which build it is comes
# from the repo config's node_version (see dsh_config_file in common.sh), a
# per-run DSH_NODE_VERSION over that, and "lts" — the ACTIVE LTS line — when
# neither has anything to say.
#
# This step never downloads this project's own release artifacts. Option A takes
# its Node out of the release tarball because install.sh unpacks that tarball
# anyway; Option B has no tarball to unpack, so fetching one only to pull node/
# out of it meant a 100+ MiB download for a single directory.
DL="$RUNTIME_DIR/downloads"
KEYS="${NODEJS_KEYS_DIR:-$HOME/.nodejs-keys}"
mkdir -p "$RUNTIME_DIR" "$DL"

# Precedence: $DSH_NODE_VERSION > the config file > the active LTS line.
CFG_SPEC="$(dsh_config_get node_version)"
if [ -n "${DSH_NODE_VERSION:-}" ]; then
	NODE_SPEC="$DSH_NODE_VERSION"
	echo "    Node spec: ${NODE_SPEC} (from DSH_NODE_VERSION)"
elif [ -n "$CFG_SPEC" ]; then
	NODE_SPEC="$CFG_SPEC"
	echo "    Node spec: ${NODE_SPEC} (from $(dsh_config_file))"
else
	NODE_SPEC="lts"
	echo "    Node spec: ${NODE_SPEC} (default: the active LTS line)"
fi
NODE_VERSION="$(resolve_node_version "$NODE_SPEC")" ||
	{
		echo "!! cannot resolve the Node version from '${NODE_SPEC}'" >&2
		exit 1
	}
echo "    target: v${NODE_VERSION} (linux-arm64, glibc)"

# --- 3a. download and unpack ----------------------------------------------
TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.xz"
BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"

# Fetch SHASUMS256.txt into $DL and verify its GPG signature when possible.
# gpg missing -> loud warning + continue (sha256 below still guards against
# download corruption); bad signature -> abort. --insecure skips the GPG part.
fetch_manifest() {
	echo "==> Fetching SHASUMS256.txt manifest ..."
	curl -fsSLo "$DL/SHASUMS256.txt" "$BASE_URL/SHASUMS256.txt"
	if [ "$INSECURE" -eq 1 ]; then
		echo "!! GPG signature check skipped (--insecure)" >&2
		return 0
	fi
	if ! command -v gpg >/dev/null 2>&1; then
		echo "!! gpg not found; skipping the signature check (pkg install gnupg, or --insecure to silence)" >&2
		return 0
	fi
	if [ ! -d "$KEYS/gpg" ]; then
		echo "==> Pulling the Node.js release keyring (one-time) ..."
		git clone --depth 1 https://github.com/nodejs/release-keys.git "$KEYS"
	fi
	curl -fsSLo "$DL/SHASUMS256.txt.sig" "$BASE_URL/SHASUMS256.txt.sig"
	echo "==> Verifying SHASUMS256.txt signature ..."
	GNUPGHOME="$KEYS/gpg" gpg --batch --verify "$DL/SHASUMS256.txt.sig" "$DL/SHASUMS256.txt" ||
		{
			echo "!! signature verification failed; aborting (file or channel compromised?)" >&2
			exit 1
		}
	echo "    signature OK"
}

# Does the tarball sitting in $DL match the (signature-verified) manifest?
tarball_sha256_ok() {
	grep -q "  ${TARBALL}\$" "$DL/SHASUMS256.txt" || return 1
	(cd "$DL" && grep "  ${TARBALL}\$" SHASUMS256.txt | sha256sum -c - >/dev/null 2>&1)
}

fetch_node() {
	mkdir -p "$DL"
	fetch_manifest
	if [ -f "$DL/$TARBALL" ] && tarball_sha256_ok; then
		echo "==> Reusing verified download: $DL/$TARBALL"
	else
		echo "==> Downloading Node.js v${NODE_VERSION} (linux-arm64, glibc; resumes a partial file) ..."
		# -C - continues an interrupted download; a server without Range support
		# (or a file too corrupt to resume) makes curl fail, which is handled
		# below by discarding and starting over.
		curl -fL -C - "$BASE_URL/$TARBALL" -o "$DL/$TARBALL" || rm -f "$DL/$TARBALL"
		if ! tarball_sha256_ok; then
			echo "    sha256 mismatch (corrupt partial?) — re-downloading from scratch"
			rm -f "$DL/$TARBALL"
			curl -fsSL "$BASE_URL/$TARBALL" -o "$DL/$TARBALL"
			tarball_sha256_ok ||
				{
					echo "!! sha256 mismatch for $TARBALL even after a fresh download; aborting" >&2
					exit 1
				}
		fi
	fi
	echo "==> sha256 OK"
	echo "==> Extracting to $NODE_ROOT"
	rm -rf "${NODE_ROOT:?}"
	mkdir -p "$NODE_ROOT"
	tar -xJf "$DL/$TARBALL" -C "$NODE_ROOT" --strip-components=1
}

installed_ver=""
if [ -x "$NODE_BIN" ]; then
	# An already-present node may still be pristine (interpreter /lib/ld-...),
	# which the kernel cannot exec on Termux; configure it before probing.
	configure_glibc_node "$NODE_BIN" || true
	installed_ver="$(run_glibc_node "$NODE_BIN" --version 2>/dev/null || true)"
fi

if [ -n "$installed_ver" ] && [[ "$installed_ver" == *"v${NODE_VERSION}"* ]]; then
	echo "    Node.js $installed_ver already present (v${NODE_VERSION})."
else
	echo "    Current node: ${installed_ver:-none}  (target: v${NODE_VERSION})"
	if ask_yes_no "Download and install Node.js v${NODE_VERSION}?"; then
		fetch_node
	else
		echo "!! Node.js is required. Aborting." >&2
		exit 1
	fi
fi
# A freshly extracted node is pristine; configure it (idempotent otherwise).
configure_glibc_node "$NODE_BIN"

if [ "$CLEAN" -eq 1 ]; then
	# Only ever the downloads dir: nothing outside it belongs to this script.
	rm -f "$DL"/*.tar.xz "$DL"/SHASUMS256.txt "$DL"/SHASUMS256.txt.sig
	echo "    Downloads cleaned (--clean)."
fi

# Verify by direct exec, which is how the `dsh` wrapper runs it. execPath must
# be node itself, not the glibc loader: dsh re-spawns process.execPath for
# helpers such as the `dsh web` browser handoff.
cat >"$RUNTIME_DIR/.v.js" <<'EOF'
console.log('node', process.version, process.platform, process.arch)
console.log('execPath', process.execPath)
EOF
run_glibc_node "$NODE_BIN" "$RUNTIME_DIR/.v.js" 2>&1
rm -f "$RUNTIME_DIR/.v.js"

# --- 5b. Write the result back to the config -------------------------------
# node_version stays exactly as the user wrote it (an "lts" there must keep
# following the LTS line on the next install), so only the two facts are
# recorded: what landed on disk and where it is. Neither is worth aborting a
# complete install over, so a failed write is a loud warning rather than an exit.
NODE_ACTUAL="$(run_glibc_node "$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || true)"
CFG="$(dsh_config_file)"
if dsh_config_set node_installed_version "${NODE_ACTUAL:-$NODE_VERSION}" &&
	dsh_config_set node_bin "$NODE_BIN"; then
	echo "    config: $CFG (node_installed_version=${NODE_ACTUAL:-$NODE_VERSION}, node_bin=$NODE_BIN)"
else
	echo "!! cannot write the config at $CFG; node is installed and usable, but" >&2
	echo "   later runs will have to resolve the version again from scratch." >&2
fi

# --- 7/8. pkg Node conflict + node/npm/npx(/pnpm) registration -------------
# Last, and only now: the glibc Node above is proven to run, so offering to
# remove the pkg Node cannot leave the device with nothing that executes JS.
echo "==> Registering the glibc Node as node/npm/npx(/pnpm)"
register_node_shims "$BIN_DIR" "$NODE_ROOT"
ensure_bin_dir_on_path "$BIN_DIR"

# The shims are the user-facing contract, so prove one of them runs by the
# absolute path (a fresh shell is not what this check depends on).
if ! "$BIN_DIR/node" --version >/dev/null 2>&1; then
	echo "!! the node shim at $BIN_DIR/node does not run. Aborting." >&2
	exit 1
fi
echo "    shim check: $BIN_DIR/node -> $("$BIN_DIR/node" --version 2>/dev/null)"

echo "==> [01] Done. Next: scripts/02-install-dsh.sh"
