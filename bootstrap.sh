#!/usr/bin/env bash
#
# Herdr plugin: setup-bootstrap
#
# Hooks `worktree.created`. Reads `<main-repo-root>/worktree_init.toml` and:
#   1. Runs the configured `setup` command inside the new worktree checkout.
#   2. Copies the configured `copy` globs from the main repo into the worktree,
#      preserving each path's location relative to the repo root.
#
# This replaces the per-project setup.sh with a single shared Herdr plugin.
#
set -euo pipefail

log()  { printf '[setup-bootstrap] %s\n' "$*"; }
warn() { printf '[setup-bootstrap] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# ── 1. Parse plugin context JSON for the new worktree checkout path ──────────
if [ -z "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
    warn "HERDR_PLUGIN_CONTEXT_JSON is empty; cannot determine worktree path"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required to parse plugin context JSON"
fi

workspace_cwd=$(python3 -c '
import json, sys
try:
    ctx = json.load(sys.stdin)
    print(ctx.get("workspace_cwd", ""))
except Exception:
    print("")
' <<< "$HERDR_PLUGIN_CONTEXT_JSON")

if [ -z "$workspace_cwd" ]; then
    warn "workspace_cwd missing from plugin context"
    exit 0
fi

if [ ! -d "$workspace_cwd" ]; then
    warn "workspace cwd does not exist: $workspace_cwd"
    exit 0
fi

# ── 2. Resolve the main repo root (first entry of git worktree list) ─────────
main_repo_root=$(git -C "$workspace_cwd" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2; exit}') || true

if [ -z "$main_repo_root" ]; then
    warn "could not determine main repo root for $workspace_cwd"
    exit 0
fi

main_repo_root=$(cd "$main_repo_root" && pwd -P)
workspace_cwd=$(cd "$workspace_cwd" && pwd -P)

if [ "$main_repo_root" = "$workspace_cwd" ]; then
    log "checkout is the main repo — nothing to bootstrap"
    exit 0
fi

# ── 3. Load worktree_init.toml from the main repo root ───────────────────────
config_file="$main_repo_root/worktree_init.toml"
if [ ! -f "$config_file" ]; then
    log "no worktree_init.toml in $main_repo_root — skipping"
    exit 0
fi

# Minimal TOML string extractor (handles top-level key = "..." with \n escapes).
toml_string() {
    local key="$1" file="$2" line val
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -n1) || true
    [ -n "$line" ] || return 1
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"   # ltrim
    val="${val%"${val##*[![:space:]]}"}"   # rtrim
    val="${val#\"}"; val="${val%\"}"       # strip surrounding quotes
    # Unescape \" -> " and \n -> newline.
    printf '%b' "$(printf '%s' "$val" | sed -e 's/\\"/"/g')"
}

setup_cmd=$(toml_string setup "$config_file" || true)
copy_globs=$(toml_string copy "$config_file" || true)

# ── 4. Run setup command ─────────────────────────────────────────────────────
if [ -n "$setup_cmd" ]; then
    log "running setup: $setup_cmd"
    (cd "$workspace_cwd" && /bin/sh -c "$setup_cmd") || die "setup command failed"
else
    log "no setup command configured"
fi

# ── 5. Copy globs from main repo into the worktree ───────────────────────────
if [ -z "$copy_globs" ]; then
    log "no copy globs configured"
    exit 0
fi

copy_one() {
    local src="$1" rel dest
    rel="${src#"$main_repo_root"/}"
    dest="$workspace_cwd/$rel"
    [ "$src" = "$dest" ] && return 0
    mkdir -p "$(dirname "$dest")"
    if [ -d "$src" ]; then
        mkdir -p "$dest"
        rsync -a "$src"/ "$dest"/
    else
        rsync -a "$src" "$dest"
    fi
    log "copied: $rel"
}

copied=0
while IFS= read -r pattern; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"   # ltrim
    pattern="${pattern%"${pattern##*[![:space:]]}"}"   # rtrim
    [ -z "$pattern" ] && continue

    matched=0
    if [[ "$pattern" == */* ]]; then
        # Anchored pattern: expand relative to the repo root.
        shopt -s nullglob dotglob
        for src in "$main_repo_root"/$pattern; do
            [ -e "$src" ] || continue
            copy_one "$src"; matched=1; copied=$((copied + 1))
        done
        shopt -u nullglob dotglob
    else
        # Bare pattern: match by name at ANY depth, pruning vcs/deps.
        while IFS= read -r src; do
            [ -n "$src" ] || continue
            copy_one "$src"; matched=1; copied=$((copied + 1))
        done < <(find "$main_repo_root" \
            -name .git -prune -o \
            -name node_modules -prune -o \
            -name "$pattern" -print)
    fi
    [ "$matched" -eq 0 ] && warn "no match for glob: $pattern"
done <<EOF
$copy_globs
EOF

log "done — $copied path(s) copied"
