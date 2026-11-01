#!/data/data/com.termux/files/usr/bin/bash
# 01-setup-glibc-node.sh — verify Termux, install glibc components, fetch Node.
#
# Steps:
#   1. Detect Termux ($PREFIX).
#   2. Detect glibc-repo / glibc / glibc-runner; ask to install if missing.
#   3. Re-check after install (still fail loudly if missing).
#   4. Resolve the target Node version. DSH_NODE_VERSION (or the repo-root
#      NODE_VERSION file) may be either an exact X.Y.Z or a bare major —
#      "24" resolves to the latest v24.x patch via nodejs.org's manifest.
#   5. Fetch the official glibc Node.js linux-arm64 binary. An already
#      downloaded tarball is REUSED when its sha256 matches, a partial one is
#      RESUMED (curl -C -); a file that still fails verification is
#      re-downloaded from scratch exactly once.
#   6. Verify the tarball: sha256 always; GPG signature too when gpg is
#      available (skip with --insecure).
#   7. Point its ELF interpreter at Termux's glibc loader so it can be exec'd
#      directly — see configure_glibc_node in common.sh for why grun's
#      `ld.so <node>` indirection breaks dsh.
#
# Flags (only meaningful when run directly; 00-setup.sh calls it bare):
#   --insecure  skip the GPG signature check (sha256 is still verified)
#   --clean     delete the tarball + manifests from downloads/ after success
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/scripts/common.sh"

INSECURE=0
CLEAN=0
for a in "$@"; do
  case "$a" in
    --insecure) INSECURE=1 ;;
    --clean)    CLEAN=1 ;;
    -h|--help)  sed -n '2,22p' "$0" >&2; exit 0 ;;
    *) echo "01-setup-glibc-node.sh: unknown option: $a" >&2
       echo "Usage: bash scripts/01-setup-glibc-node.sh [--insecure] [--clean]" >&2
       exit 2 ;;
  esac
done

RUNTIME_DIR="${DSH_RUNTIME_DIR:-$HOME/.local/opt/dsh-termux-runtime}"
# Node 版本单一事实源: 仓库根 NODE_VERSION 文件 (DSH_NODE_VERSION 仍可覆盖)。
RAW_NODE_VERSION="${DSH_NODE_VERSION:-$(tr -d '[:space:]' < "$BASE_DIR/NODE_VERSION" 2>/dev/null || true)}"
[ -n "$RAW_NODE_VERSION" ] || { echo "!! NODE_VERSION file missing/empty at $BASE_DIR/NODE_VERSION" >&2; exit 1; }
NODE_ROOT="$RUNTIME_DIR/node"
NODE_BIN="$NODE_ROOT/bin/node"

echo "==> [01] Environment check"

# --- 1. Termux detection ---------------------------------------------------
if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  echo "!! Not a Termux environment (\$PREFIX unset or missing). Aborting." >&2
  exit 1
fi
echo "    Termux detected: PREFIX=$PREFIX"

# --- 2. glibc components ---------------------------------------------------
missing=()
command -v grun >/dev/null 2>&1  || missing+=("glibc-runner")
dpkg -s glibc >/dev/null 2>&1   || missing+=("glibc")
dpkg -s glibc-repo >/dev/null 2>&1 || missing+=("glibc-repo")

if [ ${#missing[@]} -gt 0 ]; then
  echo "    Missing glibc components: ${missing[*]}"
  if ask_yes_no "Install them now (pkg install glibc-repo glibc glibc-runner)?"; then
    echo "==> Installing glibc components ..."
    pkg install -y glibc-repo glibc glibc-runner
  else
    echo "!! glibc components are required. Aborting." >&2
    exit 1
  fi
fi

# --- 3. Re-check -----------------------------------------------------------
if ! command -v grun >/dev/null 2>&1; then
  echo "!! glibc-runner (grun) still missing after install. Aborting." >&2
  exit 1
fi
echo "    glibc-runner OK: $(command -v grun)"

# --- 4. Resolve the target Node version ------------------------------------
# 裸大版本号 (仓库 NODE_VERSION 的常态, 如 "24") 解析为该线最新 patch ——
# 原独立脚本 install-node-glibc.sh 的能力, 合并后由 01 自己完成。
if [[ "$RAW_NODE_VERSION" =~ ^[0-9]+$ ]]; then
  MAJOR="$RAW_NODE_VERSION"
  case "$MAJOR" in
    24) ;;
    22) echo "!! note: dsh engines is ^22.19.0 || >=24; v22 works but is uncommon" >&2 ;;
    23) echo "!! note: v23 is an odd non-LTS line and may not satisfy dsh engines" >&2 ;;
    *)  echo "!! note: only the v24 line is verified; other majors may break the native overlay ABI" >&2 ;;
  esac
  echo "==> Resolving the latest Node v${MAJOR}.x ..."
  LIST="$(curl -fsSL "https://nodejs.org/dist/latest-v${MAJOR}.x/SHASUMS256.txt")" \
    || { echo "!! cannot fetch the latest-v${MAJOR}.x manifest (line EOL? offline?)" >&2; exit 1; }
  NODE_VERSION="$(printf '%s\n' "$LIST" \
    | sed -n 's/^[0-9a-f]\{64\}  node-v\([0-9][0-9.]*\)-linux-arm64\.tar\.xz$/\1/p' | head -1)"
  [ -n "$NODE_VERSION" ] || { echo "!! cannot parse a version out of the manifest" >&2; exit 1; }
  echo "    latest: v${NODE_VERSION}"
else
  NODE_VERSION="${RAW_NODE_VERSION#v}"
fi

TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.xz"
BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
DL="$RUNTIME_DIR/downloads"
KEYS="${NODEJS_KEYS_DIR:-$HOME/.nodejs-keys}"

# --- 5. Node.js ------------------------------------------------------------
mkdir -p "$RUNTIME_DIR"

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
  GNUPGHOME="$KEYS/gpg" gpg --batch --verify "$DL/SHASUMS256.txt.sig" "$DL/SHASUMS256.txt" \
    || { echo "!! signature verification failed; aborting (file or channel compromised?)" >&2; exit 1; }
  echo "    signature OK"
}

# Does the tarball sitting in $DL match the (signature-verified) manifest?
tarball_sha256_ok() {
  grep -q "  ${TARBALL}\$" "$DL/SHASUMS256.txt" || return 1
  ( cd "$DL" && grep "  ${TARBALL}\$" SHASUMS256.txt | sha256sum -c - >/dev/null 2>&1 )
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
      tarball_sha256_ok \
        || { echo "!! sha256 mismatch for $TARBALL even after a fresh download; aborting" >&2; exit 1; }
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
  rm -f "$DL/$TARBALL" "$DL/SHASUMS256.txt" "$DL/SHASUMS256.txt.sig"
  echo "    Downloads cleaned (--clean)."
fi

# Verify by direct exec, which is how the `dsh` wrapper runs it. execPath must
# be node itself, not the glibc loader: dsh re-spawns process.execPath for
# helpers such as the `dsh web` browser handoff.
cat > "$RUNTIME_DIR/.v.js" << 'EOF'
console.log('node', process.version, process.platform, process.arch)
console.log('execPath', process.execPath)
EOF
run_glibc_node "$NODE_BIN" "$RUNTIME_DIR/.v.js" 2>&1
rm -f "$RUNTIME_DIR/.v.js"

echo "==> [01] Done. Next: scripts/02-install-dsh.sh"
