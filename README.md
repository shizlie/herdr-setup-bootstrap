# herdr-setup-bootstrap

A [Herdr](https://herdr.sh) plugin that bootstraps every newly created worktree
from a project-local `worktree_init.toml`.

## What it does

When Herdr creates a workspace for a linked worktree, the plugin reads
`<main-repo-root>/worktree_init.toml`, then:

1. Runs the configured `setup` command inside the new checkout.
2. Copies the configured `copy` globs from the main repo into the worktree,
   preserving each path's location relative to the repo root.

This is useful for replicating per-workspace bootstrap steps that git can't
carry across worktrees: installing dependencies and seeding gitignored locals
like `.env*`, `.dev.vars`, `.wrangler`, or `public/`.

The plugin is idempotent — it only bootstraps a given checkout once, tracked by
a marker in Herdr's plugin state directory.

## Install

```bash
herdr plugin install shizlie/herdr-setup-bootstrap
```

No restart required. To remove:

```bash
herdr plugin uninstall setup-bootstrap
```

## Project config: `worktree_init.toml`

Create a `worktree_init.toml` at the root of any repo you want bootstrapped:

```toml
# Shell command run inside the new worktree checkout.
setup = "cd \"project-v3\" && bun install"

# Newline-separated glob patterns. Paths with `/` are matched relative to the
# repo root; bare names are matched at any depth. Files and directories are
# copied while preserving their relative path.
copy = ".env*\n.dev.vars\n.dev.vars.production\nlogo-wide.png\n.wrangler\npublic"
```

If a repo has no `worktree_init.toml`, the hook silently skips it.

## How it works

1. Herdr emits `workspace.created` whenever a new workspace is opened.
2. The plugin receives `HERDR_PLUGIN_CONTEXT_JSON` and checks whether the
   workspace is a linked worktree.
3. It resolves the main repo root via `git worktree list`.
4. It reads `worktree_init.toml` from the main repo root.
5. It runs `setup` and copies the `copy` globs.
6. It writes a marker to `HERDR_PLUGIN_STATE_DIR/done/` so the same checkout is
   not bootstrapped again.

## Requirements

- `python3` to parse the plugin context JSON.
- `rsync` for copying directories efficiently.

## Logs

```bash
herdr plugin log list --plugin setup-bootstrap
```

## License

MIT
