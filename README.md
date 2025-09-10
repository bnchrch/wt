# wt — Git Worktree Helper (Shell Plugin)

`wt` is a lightweight shell plugin that makes working with [Git worktrees](https://git-scm.com/docs/git-worktree) much easier.

It provides commands to create, switch, list, and clean up worktrees, while also copying or symlinking files/folders defined in a YAML manifest. It can also run a post-create command (e.g. `npm ci`) automatically.

---

## ✨ Features

- **Per-branch worktree directories**  
  Branch `feature/foo` gets a directory like `../my-repo-worktrees/feature-foo`.

- **Configurable manifest (`.worktrees`)**  
  Define which files/folders should be copied or symlinked into each worktree.

- **`wt init` bootstrap**  
  Quickly create a `.worktrees` file with sensible defaults (symlinks `.env` and `node_modules`).

- **Post-create hooks**  
  Run arbitrary commands (e.g., install dependencies) automatically after creating or switching worktrees.

- **Safety first**  
  Interactive confirmation before destructive operations (`wt remove`, `wt prune --all`), with a `--yes` flag for automation.

- **Shell plugin**  
  Runs inside your current shell so `wt switch` actually `cd`s into the worktree — no wrapper hacks needed.

---

## 📦 Installation

1. Save the script somewhere, e.g.:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/bnchrch/wt/main/wt.plugin.sh -o ~/wt.plugin.sh
   ```

2. Source it in your shell config (`~/.bashrc` or `~/.zshrc`):

   ```bash
   source ~/wt.plugin.sh
   ```

3. Reload your shell:

   ```bash
   exec $SHELL
   ```

Requirements:  
- `git` ≥ 2.25  
- [`yq`](https://github.com/mikefarah/yq) (Go version recommended)  

---

## ⚡ Usage

```bash
wt init [--force]               # Create a starter .worktrees config
wt new <branch> [<base-ref>]    # Create a new worktree and apply rules
wt switch <branch>              # Create if needed, checkout, apply rules, cd into it
wt remove [--yes] <branch>      # Remove the worktree for branch (asks to confirm)
wt prune --all [--yes]          # Prompt to delete stale worktree dirs; prunes registry
wt list                         # List registered worktrees
wt help                         # Show usage
```

### Examples

```bash
# Initialize a new config with defaults
wt init

# Create a new worktree for a feature branch
wt new feature/login origin/main

# Switch into a worktree (creates it if missing)
wt switch feature/login

# Remove a worktree safely
wt remove feature/login

# Remove without being asked (e.g. CI)
wt remove --yes feature/login

# Clean up stale directories
wt prune --all

# Non-interactive prune (CI)
wt prune --all --yes
```

---

## ⚙️ Configuration

Put a `.worktrees` file in the root of your repo (YAML format).

### Example

```yaml
# Where to put worktrees (relative to repo root or absolute)
root: ../my-repo-worktrees

# Command to run inside the worktree after create/switch
post_create: npm ci

# Files and directories to sync into each worktree
rules:
  - action: copy
    src: .env.example
    dest: .env
    opts: [if-missing]

  - action: symlink
    src: ../shared/modules
    dest: node_modules
    opts: [optional, mkdirs]

  - action: copy
    src: .vscode
    dest: .vscode
    opts: [mkdirs]
```

### Options

- **action**: `copy` or `symlink`
- **src**: path relative to repo root (may point outside via `..`)
- **dest**: path relative to the worktree directory
- **opts** (list, optional):
  - `if-missing`: only add if not already present
  - `mkdirs`: create parent directories if needed
  - `force`: overwrite existing file/folder
  - `optional`: skip silently if source is missing

---

## 🛡 Safety Flags

- `--yes` — skips confirmation prompts for `wt remove` and `wt prune --all`
- `WT_YES=1` — environment variable equivalent (useful in CI)
- `--force` — overwrite existing `.worktrees` when running `wt init`

---

## 🧩 Completions

The plugin comes with simple completions for Bash and Zsh. Branch names will auto-complete for `wt switch`, `wt new`, and `wt remove`.

---

## 🚀 Why a Plugin?

Normally, a standalone script can’t change your current directory. By sourcing this plugin into your shell, `wt switch` can `cd` you into the worktree directory directly.

---

## 📖 License

MIT — do whatever you like, just don’t blame me if it eats your homework.
