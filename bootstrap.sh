#!/usr/bin/env bash
#
# Herdr plugin: setup-bootstrap
#
# Hooks `workspace.created` and `workspace.focused`. If the workspace is a
# linked worktree that has not yet been bootstrapped, reads
# `<main-repo-root>/worktree_init.toml`, runs the configured `setup` command in
# the new checkout, and copies the configured `copy` globs from the main repo
# into the worktree.
#
# `workspace.created` catches worktrees created via the API/CLI.
# `workspace.focused` catches worktrees created via the Herdr UI (which does not
# emit `workspace.created`) and also backfills worktrees that were created
# before the plugin was installed once they are focused.
#
set -euo pipefail

log()  { printf '[setup-bootstrap] %s\n' "$*"; }
warn() { printf '[setup-bootstrap] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# ── 1. Parse plugin context JSON ─────────────────────────────────────────────
if [ -z "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
    warn "HERDR_PLUGIN_CONTEXT_JSON is empty; cannot determine workspace"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required to parse plugin context JSON"
fi

read -r workspace_cwd is_linked_worktree < <(python3 -c '
import json, sys
try:
    ctx = json.load(sys.stdin)
    wt = ctx.get("worktree") or {}
    print(ctx.get("workspace_cwd", ""), wt.get("is_linked_worktree", False))
except Exception:
    print("", "False")
' <<< "$HERDR_PLUGIN_CONTEXT_JSON")

if [ "$is_linked_worktree" != "True" ]; then
    log "workspace is not a linked worktree — skipping"
    exit 0
fi

if [ -z "$workspace_cwd" ]; then
    warn "workspace_cwd missing from plugin context"
    exit 0
fi

if [ ! -d "$workspace_cwd" ]; then
    warn "workspace cwd does not exist: $workspace_cwd"
    exit 0
fi

# ── 2. Idempotency: skip if we already bootstrapped this checkout ────────────
if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
    marker_dir="$HERDR_PLUGIN_STATE_DIR/done"
    marker="$marker_dir/$(printf '%s' "$workspace_cwd" | shasum -a 256 | cut -d' ' -f1)"
    if [ -f "$marker" ]; then
        log "already bootstrapped $workspace_cwd — skipping"
        exit 0
    fi
fi

# ── 3. Resolve the main repo root (first entry of git worktree list) ─────────
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

# ── 4. Load worktree_init.toml from the main repo root ───────────────────────
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

# ── 5. Run setup command ─────────────────────────────────────────────────────
if [ -n "$setup_cmd" ]; then
    log "running setup: $setup_cmd"
    (cd "$workspace_cwd" && /bin/sh -c "$setup_cmd") || die "setup command failed"
else
    log "no setup command configured"
fi

# ── 6. Copy globs from main repo into the worktree ───────────────────────────
if [ -z "$copy_globs" ]; then
    log "no copy globs configured"
else
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
            shopt -s nullglob dotglob
            for src in "$main_repo_root"/$pattern; do
                [ -e "$src" ] || continue
                copy_one "$src"; matched=1; copied=$((copied + 1))
            done
            shopt -u nullglob dotglob
        else
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
fi

# ── 7. Mark this checkout as bootstrapped ────────────────────────────────────
if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
    mkdir -p "$marker_dir"
    date > "$marker"
fi
