#!/data/data/com.termux/files/usr/bin/bash
# common.sh — shared helpers for the dsh-termux install scripts.
# Sourced by scripts/00-04. No shebang execution.

# --- Prompt helpers -------------------------------------------------------

# Ask a yes/no question. Default is YES. Returns 0 (yes) or 1 (no).
# Honors DSH_ASSUME_YES=1 (from the -y flag): returns the default without asking.
ask_yes_no() {
	local prompt="$1"
	local default="${2:-yes}" # yes | no
	if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
		echo "   [auto-yes] ${prompt}"
		[ "$default" = "yes" ]
		return $?
	fi
	local answer
	while :; do
		if [ "$default" = "yes" ]; then
			printf '%s [Y/n]: ' "$prompt"
		else
			printf '%s [y/N]: ' "$prompt"
		fi
		read -r answer
		case "${answer,,}" in
		"")
			[ "$default" = "yes" ]
			return $?
			;;
		y | yes) return 0 ;;
		n | no) return 1 ;;
		*) echo "   Please answer y or n." ;;
		esac
	done
}

# Ask for a value with a default; validates input with a validator function.
#   ask_input <var_name> <prompt> <default> <validator_func>
# The validator receives the candidate as $1 and returns 0 if valid.
ask_input() {
	local var="$1" prompt="$2" default="$3" validator="$4"
	if [ "${DSH_ASSUME_YES:-0}" = "1" ]; then
		printf -v "$var" '%s' "$default"
		echo "   [auto] ${prompt} -> ${default}"
		return 0
	fi
	local val
	while :; do
		printf '%s [%s]: ' "$prompt" "$default"
		read -r val
		val="${val:-$default}"
		# 空默认 + 空输入 = 用户接受「无值」语义: 直接放行, 由调用方归一 (如
		# 00-setup 的 ${DSH_WORK_DIR:-$DSH_RUNTIME_DIR/work})。空串此刻若再交给
		# validator (validate_abs_path 等) 必被拒, 提示里「empty = 默认」的承诺
		# 就成了交互死循环 (architecture 审计实测确认)。default 非空时 val 已
		# 回落为 default, 不会走到这里, 各原有调用点行为不变。
		if [ -z "$val" ]; then
			printf -v "$var" '%s' "$val"
			return 0
		fi
		if [ -z "$validator" ] || "$validator" "$val"; then
			printf -v "$var" '%s' "$val"
			return 0
		fi
		echo "   Invalid input, please try again."
	done
}

# --- Validators -----------------------------------------------------------

# Absolute path, no spaces, no leading '~'.
validate_abs_path() {
	local p="$1"
	[[ "$p" =~ ^/ ]] || {
		echo "   (must be an absolute path starting with /)"
		return 1
	}
	[[ "$p" != *" "* ]] || {
		echo "   (must not contain spaces — npm and the ELF loader path dislike them)"
		return 1
	}
	return 0
}

# A Node spec, in any of the three forms resolve_node_version accepts:
#   lts | lts/*   the ACTIVE LTS line (whatever nodejs.org currently calls LTS)
#   24            a bare major
#   24.19.0       an exact release (a leading "v" is tolerated)
# Concrete forms are also checked against dsh's engines (^22.19.0 || >=24.0.0);
# a bare major cannot prove the minor, so 22 is accepted (latest-v22.x is well
# past 22.19) and anything older is rejected.
validate_node_version() {
	local v="${1#v}"
	case "${v,,}" in
	lts | lts/\*) return 0 ;;
	esac
	if [[ "$v" =~ ^[0-9]+$ ]]; then
		if [ "$v" -lt 22 ]; then
			echo "   (dsh requires Node ^22.19.0 || >=24.0.0; ${v}.x is too old)"
			return 1
		fi
		return 0
	fi
	if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "   (expected lts, a bare major such as 24, or X.Y.Z such as 24.19.0)"
		return 1
	fi
	local major minor
	major="${v%%.*}"
	minor="${v#*.}"
	minor="${minor%%.*}"
	if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
		return 0
	fi
	echo "   (dsh requires Node ^22.19.0 || >=24.0.0; you entered ${major}.${minor})"
	return 1
}

# resolve_node_version <spec> — print the concrete X.Y.Z that <spec> names.
#
#   lts | lts/*  the ACTIVE LTS line's newest release. nodejs.org/dist/
#                index.json lists releases newest-first, so the first entry
#                that carries an LTS codename ("lts": "Krypton") is exactly
#                that line's latest patch. The maintenance line is older and
#                therefore comes later in the array — it is never picked.
#   24           the newest patch of the v24 line (latest-v24.x manifest)
#   24.19.0      itself
#
# stdout carries the version and NOTHING else, so callers may capture it; all
# narration and warnings go to stderr. Requires curl. One resolver serves both
# sides of the project: the device path (01) and the release build
# (a release build, if anyone makes one), so "lts" means one thing.
resolve_node_version() {
	local spec="${1#v}" list v
	spec="$(printf '%s' "$spec" | tr -d '[:space:]')"
	[ -n "$spec" ] || {
		echo "!! resolve_node_version: empty Node version spec" >&2
		return 1
	}

	case "${spec,,}" in
	lts | lts/\*)
		echo "==> Resolving the active LTS line (nodejs.org/dist/index.json) ..." >&2
		list="$(curl -fsSL https://nodejs.org/dist/index.json)" ||
			{
				echo "!! cannot fetch nodejs.org/dist/index.json (offline?)" >&2
				return 1
			}
		v="$(printf '%s\n' "$list" | awk -F'"' '
        /"version": *"v/ { ver = $4 }
        /"lts": *"/      { print substr(ver, 2); exit }')"
		[ -n "$v" ] || {
			echo "!! cannot parse an LTS release out of index.json" >&2
			return 1
		}
		# The LTS line moves on its own schedule. Native packages npm installs
		# are prebuilt for specific node majors (NODE_MODULE_VERSION), so say it
		# out loud when the resolved major leaves the lines this project
		# exercises — the failure belongs here, not in a module-load error later.
		case "${v%%.*}" in
		22 | 24) ;;
		*) echo "!! note: the active LTS line resolved to v${v}, outside the exercised v22/v24 lines; every native package dsh installs must ship a v${v%%.*} prebuild" >&2 ;;
		esac
		printf '%s\n' "$v"
		return 0
		;;
	esac

	if [[ "$spec" =~ ^[0-9]+$ ]]; then
		case "$spec" in
		24) ;;
		22) echo "!! note: dsh engines is ^22.19.0 || >=24; v22 works but is uncommon" >&2 ;;
		23) echo "!! note: v23 is an odd non-LTS line and may not satisfy dsh engines" >&2 ;;
		*) echo "!! note: only the v22/v24 lines are exercised; dsh's native packages may ship no prebuild for v${spec}" >&2 ;;
		esac
		echo "==> Resolving the latest Node v${spec}.x ..." >&2
		list="$(curl -fsSL "https://nodejs.org/dist/latest-v${spec}.x/SHASUMS256.txt")" ||
			{
				echo "!! cannot fetch the latest-v${spec}.x manifest (line EOL? offline?)" >&2
				return 1
			}
		v="$(printf '%s\n' "$list" |
			sed -n 's/^[0-9a-f]\{64\}  node-v\([0-9][0-9.]*\)-linux-arm64\.tar\.xz$/\1/p' | head -1)"
		[ -n "$v" ] || {
			echo "!! cannot parse a version out of the latest-v${spec}.x manifest" >&2
			return 1
		}
		printf '%s\n' "$v"
		return 0
	fi

	validate_node_version "$spec" >&2 ||
		{
			echo "!! resolve_node_version: unusable Node version spec: $spec" >&2
			return 1
		}
	printf '%s\n' "$spec"
}

# A bare port number 1..65535.
validate_port() {
	local p="$1"
	[[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# A dsh profile name: one shell-safe token (web, headless, tui, ...).
# The name is handed to dsh as `--profile <name>`, so nothing that needs
# quoting belongs here.
validate_profile_name() {
	local p="$1"
	if [[ "$p" =~ ^[A-Za-z0-9._@-]+$ ]]; then
		return 0
	fi
	echo "   (expected a single profile name, e.g. web or headless)"
	return 1
}

# --- Project config --------------------------------------------------------
# <repo or runtime root>/config — ONE file, read by both sides of the project:
#
#   node_version            lts | 24 | X.Y.Z  (input; device default = lts)
#   npm_version             dsh dist-tag or exact version (input)
#   pnpm_version            pnpm spec — stay on the 10 line, see the file
#   node_installed_version  written by 01 after a successful install
#   node_bin                absolute path to that node, also written by 01
#
# Plain key=value lines, parsed and never sourced: a config file is data, and a
# stray `$(...)` in it must not execute. DSH_CONFIG_FILE overrides the location
# (the test sandbox points it at its own copy so a test never edits the real
# one).
DSH_ROOT="${DSH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

dsh_config_file() {
	printf '%s\n' "${DSH_CONFIG_FILE:-$DSH_ROOT/config}"
}

# dsh_config_get <key> — print the value; empty when the file or key is absent.
dsh_config_get() {
	local f
	f="$(dsh_config_file)"
	[ -r "$f" ] || return 0
	sed -n "s/^[[:space:]]*$1=//p" "$f" | tail -1
}

# dsh_config_set <key> <value> — upsert one key, keeping every other line
# (comments included) as it was. The rewrite is atomic (tmp + mv) so an
# interrupted write cannot truncate the config, and the file stays 0600.
dsh_config_set() {
	local f tmp
	f="$(dsh_config_file)"
	mkdir -p "$(dirname "$f")" || return 1
	tmp="$f.tmp.$$"
	if [ -f "$f" ]; then
		grep -v "^[[:space:]]*$1=" "$f" >"$tmp" || :
	else
		: >"$tmp"
	fi
	printf '%s=%s\n' "$1" "$2" >>"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	chmod 600 "$tmp" 2>/dev/null || true
	mv "$tmp" "$f" || {
		rm -f "$tmp"
		return 1
	}
}

# --- Patch-set identity -----------------------------------------------------
# dsh_patch_set_signature <dir> — content identity of a patch set: the three
# updater scripts plus every patch file, in glob order. Equal signatures mean
# the runtime already carries exactly what a release publishes, so no version
# number has to be invented or kept in sync anywhere. cksum keeps it
# dependency-free (the same fallback patch-lib relies on): this is a change
# detector, not crypto.
dsh_patch_set_signature() {
	local dir="$1"
	{
		cat "$dir/scripts/update-dsh.sh" "$dir/scripts/common.sh" \
			"$dir/scripts/patch-lib.sh" 2>/dev/null
		cat "$dir"/patches/*.patch 2>/dev/null
	} | cksum | awk '{print $1}'
}

# --- dsh_fetch: the one download helper for shipped scripts ----------------
#
# One implementation of the rules the test harness learned the hard way and
# the device paths used to re-learn per call site:
#   - NEVER resume (-c / wget -c): a proxied resume can splice a "new head +
#     old tail" corrupt file that then passes any check computed from itself
#     (.test-install incident). Every fetch is a fresh file.
#   - ATOMIC replace: download to "<dest>.part" and only mv -f into place on
#     success — a failed fetch must never destroy an existing good file at
#     <dest> (a mistyped tag once zeroed pinned baseline assets).
#   - Optional integrity gate: --gzip runs `gzip -t` on the staged part
#     before the rename, so a truncated download fails as "corrupt download"
#     here instead of as a confusing tar error three steps later.
#
#   dsh_fetch [--gzip] [--quiet] [--max-time N] <url> <dest>
#
#   --gzip        verify the staged download with gzip -t before mv
#   --quiet       suppress the failure chatter (expected-miss probe paths;
#                 the caller narrates what a miss means)
#   --max-time N  passed to curl; default none — large tarballs on slow
#                 networks must not be killed mid-flight
#
# Retries: curl --retry (transient failures only; a 404 "asset missing"
# fails fast by design). Default 3, override with DSH_FETCH_RETRY.
# The helper does NOT create <dest>'s directory — callers stage their own.
# Requires curl.
dsh_fetch() {
	local gzip_check=0 quiet=0 max_time=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--gzip) gzip_check=1 ;;
		--quiet) quiet=1 ;;
		--max-time)
			[ $# -ge 2 ] || {
				echo "!! dsh_fetch: --max-time needs a value" >&2
				return 2
			}
			max_time="$2"
			shift
			;;
		-*)
			echo "!! dsh_fetch: unknown option: $1" >&2
			return 2
			;;
		*) break ;;
		esac
		shift
	done
	if [ $# -ne 2 ]; then
		echo "!! dsh_fetch: usage: dsh_fetch [--gzip] [--quiet] [--max-time N] <url> <dest>" >&2
		return 2
	fi
	local url="$1" dest="$2" tmp rc=0
	local -a curl_cmd=(curl -fL --retry "${DSH_FETCH_RETRY:-3}" --retry-delay 2)
	[ -z "$max_time" ] || curl_cmd+=(--max-time "$max_time")
	tmp="$dest.part"
	rm -f "$tmp"
	"${curl_cmd[@]}" -o "$tmp" "$url" || rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$tmp"
		[ "$quiet" = 1 ] || {
			echo "!! dsh_fetch: download failed (curl exit $rc): $url" >&2
			echo "   any previous file at $dest was left untouched; behind a" >&2
			echo "   proxy, export https_proxy/http_proxy first." >&2
		}
		return 1
	fi
	if [ "$gzip_check" = 1 ] && ! gzip -t "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		[ "$quiet" = 1 ] || echo "!! dsh_fetch: downloaded file is not valid gzip (truncated?): $url" >&2
		return 1
	fi
	mv -f "$tmp" "$dest"
}

# --- glibc Node ------------------------------------------------------------

# Termux's glibc prefix; exported inside a glibc-runner shell, defaulted here.
glibc_prefix() {
	echo "${GLIBC_PREFIX:-/data/data/com.termux/files/usr/glibc}"
}

# Run the configured Node the same way the generated `dsh` wrapper does.
#   run_glibc_node <node_bin> [args...]
run_glibc_node() {
	local node_bin="$1"
	shift
	env -u LD_PRELOAD PATH="$(glibc_prefix)/bin:$PATH" "$node_bin" "$@"
}

# Point the official Node binary's ELF interpreter at Termux's glibc loader so
# the kernel can exec node DIRECTLY instead of running it through `grun`.
#
# Why this matters: grun launches a glibc binary as `ld.so <binary>` (the final
# `exec ... ld.so $@` in glibc-runner.sh). The program the kernel executed is
# then the LOADER, so `/proc/self/exe` — and therefore Node's
# `process.execPath` — is `ld-linux-aarch64.so.1`, not node. dsh re-spawns
# `process.execPath` to run helpers, including the `dsh web` browser handoff,
# which therefore died with:
#     ld-linux-aarch64.so.1: unrecognized option '--input-type=module'
# grun additionally word-splits its arguments (`source ... $@` and
# `exec ld.so $@`, both unquoted), so `dsh "two words"` arrived as two argv
# entries. Exec'ing node directly fixes both.
#
# ONLY --set-interpreter. Combining it with --set-rpath in a single patchelf run
# produces a Node binary that SEGFAULTS (verified on node 22.20.0 + patchelf
# 0.19.1/aarch64: either option alone is fine, the two together are not). No
# rpath is needed anyway — Termux's glibc loader already searches its own lib dir.
#
# The swap is copy -> patch -> verify -> atomic rename, never an in-place
# rewrite. A running dsh has this binary mmap'd, and rewriting those pages under
# it raises SIGBUS/SIGSEGV and kills the live process (this is exactly how an
# in-place `grun -c` killed a running `dsh web` during development). `mv` only
# replaces the directory entry, so running processes keep their inode untouched,
# and verifying the patched copy first means a bad patch can never replace a
# working node.
#
#   configure_glibc_node <node_bin>
configure_glibc_node() {
	local node_bin="$1"
	local prefix loader current staged version
	prefix="$(glibc_prefix)"

	if [ ! -x "$node_bin" ]; then
		echo "!! configure_glibc_node: '$node_bin' is missing or not executable" >&2
		return 1
	fi
	if ! command -v patchelf >/dev/null 2>&1; then
		echo "!! configure_glibc_node: patchelf not found (it ships with glibc-runner)" >&2
		return 1
	fi
	loader="$(ls "$prefix"/lib/ld-linux-*.so.* 2>/dev/null | head -1 || true)"
	if [ -z "$loader" ]; then
		echo "!! configure_glibc_node: no glibc loader found in $prefix/lib" >&2
		return 1
	fi

	current="$(patchelf --print-interpreter "$node_bin" 2>/dev/null || true)"
	if [ "$current" = "$loader" ]; then
		echo "    Node already configured for direct exec."
		return 0
	fi

	staged="$node_bin.dsh-configure.$$"
	rm -f "$staged"
	echo "    Configuring Node for direct exec (interpreter -> $loader) ..."
	if ! cp "$node_bin" "$staged"; then
		rm -f "$staged"
		echo "!! configure_glibc_node: could not stage a copy (disk space?); Node left unchanged" >&2
		return 1
	fi
	chmod +x "$staged"
	if ! patchelf --set-interpreter "$loader" "$staged"; then
		rm -f "$staged"
		echo "!! configure_glibc_node: patchelf failed; Node left unchanged" >&2
		return 1
	fi
	# The patched COPY must prove it runs before it may replace a working node.
	version="$(env -u LD_PRELOAD "$staged" --version 2>/dev/null || true)"
	if [ -z "$version" ]; then
		rm -f "$staged"
		echo "!! configure_glibc_node: the patched Node does not run; Node left unchanged" >&2
		return 1
	fi
	mv -f "$staged" "$node_bin"
	echo "    Node configured for direct exec: $version"
}

# --- dsh wrapper ----------------------------------------------------------

# Write the Termux `$BROWSER` opener the wrapper points at.
#
# dsh reaches $BROWSER from two call sites that need DIFFERENT Android intents:
#   - `dsh web` passes an http(s) URL, through the `open` package's bundled
#     freedesktop xdg-open (which consults $BROWSER before any desktop probe);
#   - host.openPath passes a FILE PATH for .html/.htm/.xhtml/.svg, because
#     dsh's native-path-opener prefers a named browser for documents a browser
#     renders and reads $BROWSER directly to find one.
# `am start -d <bare path>` cannot resolve an Intent (no scheme, exits 1), while
# TermuxOpenReceiver builds the content:// URI a file needs. So dispatch on the
# argument instead of forcing either tool to cover both.
#
#   write_dsh_opener <opener_path>
write_dsh_opener() {
	local opener="$1"
	cat >"$opener" <<'DSH_OPENER'
#!/data/data/com.termux/files/usr/bin/sh
# dsh-termux-open — the $BROWSER opener the dsh wrapper installs on Termux.
# Generated by dsh-termux; regenerated by every install/update, so do not edit.
#
# `dsh web` hands this an http(s) URL, while dsh's native path opener hands it a
# FILE PATH for .html/.htm/.xhtml/.svg documents. Those need different Android
# intents: `am start -d <bare path>` cannot resolve an Intent, and only
# TermuxOpenReceiver builds the content:// URI a local file needs.
set -u

target="${1:-}"
if [ -z "$target" ]; then
  echo "dsh-termux-open: expected one URL or file path" >&2
  exit 2
fi

case "$target" in
  # What a browser handoff actually means: am start -a VIEW -d <url>.
  http://*|https://*) tool=termux-open-url ;;
  # File paths (and any other scheme): termux-open handles both, and is what
  # Termux's own /usr/bin/xdg-open symlink points at.
  *) tool=termux-open ;;
esac

if ! command -v "$tool" >/dev/null 2>&1; then
  echo "dsh-termux-open: $tool not found; it ships in Termux's termux-tools package" >&2
  exit 127
fi

exec "$tool" "$target"
DSH_OPENER
	chmod +x "$opener"
}

# Write the `dsh` launcher: it execs the configured Node DIRECTLY (never
# through grun) and teaches the browser handoff about Android. Emits the opener
# above next to it.
#
# Why not grun: see configure_glibc_node. grun runs `ld.so <node>`, which makes
# `process.execPath` the loader and breaks every dsh helper that re-spawns it —
# the `dsh web` browser handoff most visibly — and it word-splits arguments.
# This wrapper reproduces the only environment glibc-runner actually set up for
# node: no bionic LD_PRELOAD, and its own bin dir first on PATH.
#
# Why the $BROWSER line: `process.platform` is "linux" under glibc Node, so the
# `open` package that dsh hands `dsh web` URLs to prefers its own bundled
# freedesktop `xdg-open`. Android has no freedesktop desktop, so that script
# walks x-www-browser/firefox/lynx/w3m..., finds none, and exits 3 with
# "no method available". `$BROWSER` is the first hook it consults, and dsh's own
# native-path-opener reads it directly, so one variable fixes both without
# patching dsh.
#
#   write_dsh_wrapper <wrapper_path> <node_bin> <dsh_bin> [updater_path]
#
# With <updater_path> set, the wrapper also owns a `dsh update` shortcut: when
# the FIRST argument is exactly "update", it execs bash on that updater with
# the remaining argv, so `dsh update -t next -y` runs the bundled
# update-dsh.sh with no repo checkout. Upstream dsh has no `update`
# subcommand or --update option (the CLI top level is only `web` and
# `plugin`, see upstream apps/cli/src/args.ts) and a bare `dsh update`
# previously died with "error: --profile <name> is required", so matching $1
# shadows nothing. Only $1 is ever inspected — inner arguments such as
# `--profile tui update ...` still pass through to the booted app untouched.
# Callers without an updater (e.g. CI's three-argument check) simply get no
# branch emitted; a surplus positional argument would be ignored regardless.
#
# Every install path sources this one file (00-setup copies it into the
# runtime), so there is exactly one copy of these texts — nothing to mirror.
write_dsh_wrapper() {
	local wrapper="$1" node_bin="$2" dsh_bin="$3" updater="${4:-}"
	local opener
	opener="$(cd "$(dirname "$wrapper")" && pwd)/dsh-termux-open"
	write_dsh_opener "$opener"
	cat >"$wrapper" <<'DSH_WRAPPER_HEAD'
#!/data/data/com.termux/files/usr/bin/bash
# dsh wrapper generated by dsh-termux (glibc Node, exec'd directly).
# Accepts the same arguments as the original dsh CLI.

# Node is exec'd DIRECTLY, not through grun. grun runs `ld.so <node>`, so
# /proc/self/exe — and thus process.execPath — became the glibc loader instead
# of node; dsh re-spawns process.execPath for helpers such as the `dsh web`
# browser handoff, which then failed with
# "ld-linux-aarch64.so.1: unrecognized option '--input-type=module'". grun also
# word-split its arguments, so `dsh "two words"` arrived as two argv entries.
# Node's ELF interpreter was pointed at Termux's glibc loader at install time
# (configure_glibc_node), so the two lines below are all the environment
# glibc-runner actually provided.

# Termux's bionic preload must not leak into a glibc process.
unset LD_PRELOAD
# glibc-runner put its own bin dir first; keep that so child tools match.
export PATH="/data/data/com.termux/files/usr/glibc/bin:$PATH"

# Termux browser handoff: Android has no freedesktop desktop, so the bundled
# xdg-open that dsh's `open` dependency runs exits 3 with "no method available"
# and `dsh web` never reaches a browser. $BROWSER is the hook xdg-open consults
# first, and dsh's native path opener reads it directly; point both at the
# Android-intent opener beside this wrapper. An inherited $BROWSER always wins.
DSH_WRAPPER_HEAD
	printf 'if [ -z "${BROWSER:-}" ] && [ -x "%s" ]; then export BROWSER="%s"; fi\n\n' \
		"$opener" "$opener" >>"$wrapper"
	# Update shortcut (see the function header): only $1 is intercepted; every
	# other invocation falls through to the real dsh untouched. The branch sits
	# after "unset LD_PRELOAD", so the updater inherits exactly the environment
	# the wrapper keeps for node. A missing updater script fails with its own
	# explicit message instead of dsh's unrelated "--profile required" error.
	if [ -n "$updater" ]; then
		cat >>"$wrapper" <<DSH_WRAPPER_UPDATE
if [ "\${1:-}" = "update" ]; then
  if [ -f "${updater}" ]; then
    shift
    exec bash "${updater}" "\$@"
  fi
  echo "dsh update: updater script not found at ${updater}" >&2
  echo "       reinstall the runtime, or run scripts/update-dsh.sh directly." >&2
  exit 127
fi

DSH_WRAPPER_UPDATE
	fi
	printf 'exec "%s" --expose-internals "%s" "$@"\n' "$node_bin" "$dsh_bin" >>"$wrapper"
	chmod +x "$wrapper"
}
# --- node/npm/npx shims ----------------------------------------------------

# Marker line left inside every generated shim; grep -qF this for idempotency
# (ours -> silent overwrite on every install/update; foreign file -> ask).
DSH_NODE_SHIM_TAG="# dsh-termux node shim"

# _emit_node_shim <path> <exec_line>
# Write one shim. A file that carries the marker is ours -> overwrite silently
# (regeneration is the update path); a foreign file is never clobbered without
# an explicit yes, and the default keeps it (also what DSH_ASSUME_YES=1 does).
_emit_node_shim() {
	local target="$1" exec_line="$2"
	if [ -e "$target" ] || [ -L "$target" ]; then
		if ! grep -qF "$DSH_NODE_SHIM_TAG" "$target" 2>/dev/null &&
			! ask_yes_no "Replace existing $target with the dsh-termux shim?" no; then
			echo "    Skipped $target (existing file kept; it stays ahead of the glibc shim on PATH)."
			return 0
		fi
	fi
	cat >"$target" <<DSH_SHIM
#!/data/data/com.termux/files/usr/bin/bash
$DSH_NODE_SHIM_TAG (generated by dsh-termux; do not edit).
# Reproduces the environment the dsh wrapper provides (dsh-termux
# scripts/common.sh): Termux's bionic LD_PRELOAD must not leak into a glibc
# process, and glibc-runner's bin dir comes first so child tools match.
unset LD_PRELOAD
export PATH="/data/data/com.termux/files/usr/glibc/bin:\$PATH"
DSH_SHIM
	printf '%s\n' "$exec_line" >>"$target"
	chmod +x "$target"
	echo "    Shim written: $target"
}

# write_node_shims <bin_dir> <node_root>
# Register the glibc Node as plain `node` / `npm` / `npx` commands: wrapper
# scripts in <bin_dir> — the same dir as the `dsh` symlink, which the
# install prepends to PATH. Wrappers, not symlinks, because the point is the
# environment (unset LD_PRELOAD + glibc bin dir first): exactly what the `dsh`
# wrapper does for dsh itself. npm/npx exec the tarball's npm/npx-cli.js
# through the real node binary, so process.execPath stays node — the same
# direct-exec discipline configure_glibc_node established.
# `pnpm` joins them when the runtime bundles it (build-runtime.sh block 2b):
# `dsh plugin` spawns pnpm off PATH (exit 127 otherwise), and the shim's
# exec line runs the bundled pnpm.cjs through the real node binary — no
# device-side download. Older runtimes without pnpm degrade to a warning.
# Idempotent; see register_node_shims for the install-time conflict prompt.
write_node_shims() {
	local bin_dir="$1" node_root="$2"
	local node_bin="$node_root/bin/node"
	local npm_cli="$node_root/lib/node_modules/npm/bin/npm-cli.js"
	local npx_cli="$node_root/lib/node_modules/npm/bin/npx-cli.js"
	local pnpm_js="$node_root/lib/node_modules/pnpm/bin/pnpm.cjs"
	if [ ! -x "$node_bin" ]; then
		echo "!! write_node_shims: '$node_bin' missing or not executable" >&2
		return 1
	fi
	if [ ! -f "$npm_cli" ]; then
		echo "!! write_node_shims: '$npm_cli' missing (unexpected Node layout)" >&2
		return 1
	fi
	mkdir -p "$bin_dir"
	_emit_node_shim "$bin_dir/node" "exec \"$node_bin\" \"\$@\""
	_emit_node_shim "$bin_dir/npm" "exec \"$node_bin\" \"$npm_cli\" \"\$@\""
	if [ -f "$npx_cli" ]; then
		_emit_node_shim "$bin_dir/npx" "exec \"$node_bin\" \"$npx_cli\" \"\$@\""
	else
		echo "    npx-cli.js not found; npx shim skipped (npm exec still works)." >&2
	fi
	if [ -f "$pnpm_js" ]; then
		_emit_node_shim "$bin_dir/pnpm" "exec \"$node_bin\" \"$pnpm_js\" \"\$@\""
	else
		echo "    pnpm not bundled in this runtime; pnpm shim skipped." >&2
		echo "    NOTE: 'dsh plugin' needs pnpm on PATH — upgrade the runtime to get it." >&2
	fi
}

# termux_pkg_node_packages — print the pkg-owned packages that provide their
# own bionic node/npm, one per line, in a fixed order. Empty output = none.
#
# dpkg is pkg's backend, so only dpkg-owned installs qualify: a bare
# $PREFIX/bin/node of unknown origin is not something this repo may remove.
# npm and pnpm are separate Termux packages here — they shadow the glibc
# shims just as nodejs does, so they are offered for removal too.
termux_pkg_node_packages() {
	command -v dpkg >/dev/null 2>&1 || return 0
	local p
	for p in nodejs nodejs-lts npm pnpm; do
		dpkg -s "$p" >/dev/null 2>&1 && echo "$p"
	done
}

# termux_pkg_node_installed — true when any of the above is present.
termux_pkg_node_installed() {
	[ -n "$(termux_pkg_node_packages)" ]
}

# ensure_bin_dir_on_path <bin_dir> — prepend <bin_dir> to PATH in ~/.bashrc,
# once, inside a tagged block. The tag both makes this idempotent and lets a
# reader (or a test) find the line later. Asked interactively; -y accepts.
ensure_bin_dir_on_path() {
	local bin_dir="$1" bashrc="$HOME/.bashrc" tag="# dsh-termux"
	if grep -qF "$tag" "$bashrc" 2>/dev/null; then
		echo "    ~/.bashrc already tagged with $tag; leaving it unchanged."
		return 0
	fi
	if ! ask_yes_no "Add '$bin_dir' to PATH in ~/.bashrc (tagged $tag)?"; then
		echo "    Skipped PATH setup (run the tools as '$bin_dir/<name>')."
		return 0
	fi
	printf '\n%s\n# Prepend dsh-termux bin dir so the dsh wrapper and the glibc\n# node/npm shims resolve here.\nexport PATH="%s:$PATH"\n' \
		"$tag" "$bin_dir" >>"$bashrc"
	echo "    Appended to $bashrc (tagged $tag):"
	echo "      export PATH=\"$bin_dir:\$PATH\""
}

# register_node_shims <bin_dir> <node_root>
# Install-time entry: surface the conflict with a Termux pkg Node FIRST —
# both provide node/npm, and our shims win in every shell that sources
# ~/.bashrc because the install prepends <bin_dir> — then write the shims.
# Two deliberate guards:
#   - `uname -o` must say Android, so the question can never fire on a
#     Debian/WSL/CI host that merely happens to have dpkg+nodejs installed;
#   - the uninstall prompt DEFAULTS TO NO, so even -y (auto-accept) never
#     removes a system package — declining just keeps both, with a warning.
register_node_shims() {
	local bin_dir="$1" node_root="$2" pkgs
	pkgs="$(termux_pkg_node_packages | tr '\n' ' ')"
	pkgs="${pkgs% }"
	if [ "$(uname -o 2>/dev/null || true)" = "Android" ] && [ -n "$pkgs" ]; then
		echo "==> Termux pkg Node stack detected: $pkgs (bionic node/npm in \$PREFIX/bin)"
		if ask_yes_no "Uninstall them so the glibc shims are unambiguous?" no; then
			if command -v pkg >/dev/null 2>&1; then
				# shellcheck disable=SC2086  # $pkgs is a list: "nodejs nodejs-lts npm"
				pkg uninstall -y $pkgs ||
					echo "!! pkg uninstall failed; Termux Node kept (the shims will shadow it)." >&2
			else
				echo "!! pkg not found; nothing removed. Termux Node kept (the shims will shadow it)." >&2
			fi
		else
			echo "    Termux Node stack kept. NOTE: the glibc shims in $bin_dir shadow it"
			echo "    in every shell that sources ~/.bashrc (the dsh-termux PATH line)."
		fi
	fi
	echo "==> Registering node/npm/npx/pnpm shims (as bundled) into $bin_dir"
	write_node_shims "$bin_dir" "$node_root"
}

# native_prebuild_entries — 原生依赖注册表: "包名:构建后必须存在的产物"。
# 唯一事实源; 编译 (build_native_addons) 与两端自检 (verify_native_prebuilds) 都从
# 这里派生, 新增原生依赖只改这里。设备侧**不再**下载任何预编译资产: 当前 dsh 的
# 依赖树里没有需要编译的包 (见 PATCHES.md), 需要编译的只可能在构建机上进行。

native_prebuild_entries() {
	cat <<'NATIVE_EOF'
fs-ext:build/Release/fs_ext.node
NATIVE_EOF
}

# build_native_addons <work_dir> <node_bin> <npm_cli>
# 编译「不发 prebuild 的原生依赖」。dsh 一律以 --ignore-scripts 安装: koffi 自带
# linux-arm64 prebuild, npm 直接解析, 不需要构建脚本; 但 dsh >= 0.1.3 的会话租约
# 经 fs-ext 取 flock(2), 而 fs-ext 走 node-gyp、不发任何 prebuild —— 不补这一步,
# 任何 npm 路径装出的 0.1.3 都在启动时死掉 ("Cannot find module
# './build/Release/fs_ext.node'", 2026-09-08 首见于 patch-check @alpha)。
# 只应在**有工具链**的机器上调用 (CI runner / release 构建): Termux 设备没有
# glibc gcc, 所以设备侧只做 verify_native_prebuilds 的自检, 不编译也不下载。
build_native_addons() {
	local work_dir="$1" node_bin="$2" npm_cli="$3" entry pkg artifact pkg_dir
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		IFS=: read -r pkg artifact <<<"$entry"
		pkg_dir="$work_dir/node_modules/$pkg"
		if [ ! -f "$pkg_dir/package.json" ]; then
			echo "    -- $pkg: this dsh build does not use it; skipped"
			continue
		fi
		if [ -f "$pkg_dir/$artifact" ]; then
			echo "    -- $pkg already carries $artifact; skipped"
			continue
		fi
		echo "    building $pkg (node-gyp: python3/make/g++ must be on PATH)..."
		# npm rebuild 在「当前目录的项目」里找包 —— 调用方未必 cd 进过 work_dir
		# (patch-check 就没有), 在仓库根上它会"成功地重建 0 个包"并返回 0, 再靠
		# 下面的产物断言兜住。这里显式进 work_dir, 重建的必然是目标树。
		# npm_cli 有两种形态: npm-cli.js 路径 (经 node 执行, build-runtime 的用法)
		# 或 PATH 上的 npm 命令 (composite action 的默认)。按形态分派, 否则
		# `node npm rebuild` 会把 npm 当脚本路径, 报 MODULE_NOT_FOUND。
		if [ "${npm_cli%.js}" != "$npm_cli" ]; then
			npm_invoke=("$node_bin" "$npm_cli")
		else
			npm_invoke=("$npm_cli")
		fi
		if ! (cd "$work_dir" && "${npm_invoke[@]}" rebuild --foreground-scripts "$pkg"); then
			echo "!! npm rebuild $pkg failed — the runtime would not boot without it." >&2
			return 1
		fi
		if [ ! -f "$pkg_dir/$artifact" ]; then
			echo "!! $pkg built no $artifact (install script ran but produced nothing?)" >&2
			return 1
		fi
		# 真装载自检: 用将要在设备上跑它的同一个 node require 一遍。构建产物存在
		# 但 ABI/平台不符时, 只有这一步能当场抓住。
		if ! (cd "$work_dir" && "$node_bin" -e "require('$pkg')"); then
			echo "!! $pkg cannot be loaded by $node_bin (ABI/platform mismatch?)" >&2
			return 1
		fi
		echo "    built & loaded: $pkg -> $artifact"
	done < <(native_prebuild_entries)
}

# verify_native_prebuilds <work_dir> <node_bin>
# 断言: 注册表里每个**已安装**的原生依赖, 其产物必须在场且能被该 node 装载。
# 消费方: r2 (shipped tarball 的发布物断言)、02 与 update-dsh (装/更新后本机自检)。
verify_native_prebuilds() {
	local work_dir="$1" node_bin="$2" entry pkg artifact pkg_dir
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		IFS=: read -r pkg artifact <<<"$entry"
		pkg_dir="$work_dir/node_modules/$pkg"
		[ -f "$pkg_dir/package.json" ] || continue # 该 dsh 版本不用它
		if [ ! -f "$pkg_dir/$artifact" ]; then
			echo "!! $pkg is installed but $artifact is missing (native addon never built?)" >&2
			return 1
		fi
		if ! (cd "$work_dir" && "$node_bin" -e "require('$pkg')"); then
			echo "!! $pkg cannot be loaded by $node_bin (ABI/platform mismatch?)" >&2
			return 1
		fi
		echo "    OK native addon loads: $pkg -> $artifact"
	done < <(native_prebuild_entries)
}
