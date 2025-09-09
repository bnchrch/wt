# wt (shell plugin) — Git worktree helper with YAML config
# Commands:
#   wt init                         # create a starter .workspaces in repo root
#   wt new <branch> [<base-ref>]
#   wt switch <branch>              # creates if needed, checks out, cd's into it
#   wt remove [--yes] <branch>      # confirmation (skippable with --yes)
#   wt prune --all [--yes]          # prompts per stale dir (skippable with --yes)
#   wt list
#   wt help
#
# Requires: git, yq
# Config file (optional): <repo>/.workspaces   (YAML; no extension)
#   root: ../my-repo-worktrees
#   post_create: npm ci
#   rules:
#     - action: copy|symlink
#       src:  path/relative/to/repo
#       dest: path/relative/to/worktree
#       opts: [if-missing, mkdirs, force, optional]

# -------- small utils (stay polite in user shells) --------------------------
_wt_log() { printf '[wt] %s\n' "$*" >&2; }
_wt_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
_wt_need() { command -v "$1" >/dev/null 2>&1 || { _wt_die "Missing dependency: $1"; return 1; }; }

# -------- repo helpers -------------------------------------------------------
_wt_git_root() { git rev-parse --show-toplevel 2>/dev/null; }
_wt_repo_name() { basename "$(_wt_git_root)"; }
_wt_cfg_path() { printf '%s/.workspaces' "$(_wt_git_root)"; }     # <— renamed
_wt_have_cfg() { [[ -f "$(_wt_cfg_path)" ]]; }
_wt_sanitize_branch() { printf '%s' "${1//\//-}"; }               # feature/x -> feature-x
_wt_default_root() { printf '%s/%s-worktrees' "$(cd "$(_wt_git_root)/.."; pwd)" "$(_wt_repo_name)"; }

# -------- YAML accessors (yq) -----------------------------------------------
_wt_cfg_root_abs() {
  local repo root
  repo="$(_wt_git_root)" || return 1
  if _wt_have_cfg; then
    root="$(yq -r '.root // ""' "$(_wt_cfg_path)")" || return 1
    if [[ -n "$root" ]]; then
      [[ "$root" = /* ]] && { printf '%s' "$root"; return 0; }
      printf '%s/%s' "$repo" "$root"; return 0
    fi
  fi
  _wt_default_root
}

_wt_cfg_post_create() {
  _wt_have_cfg || { printf ''; return 0; }
  yq -r '.post_create // ""' "$(_wt_cfg_path)"
}

# emit: action \t abs_src \t dest_rel \t csv_opts
_wt_cfg_rules_tsv() {
  local repo; repo="$(_wt_git_root)" || return 0
  _wt_have_cfg || return 0
  yq -o=tsv '.rules[] | [.action, .src, .dest, ((.opts // []) | join(","))]' "$(_wt_cfg_path)" \
  | while IFS=$'\t' read -r action src dest opts; do
      [[ -z "${opts:-}" ]] && opts=""
      printf '%s\t%s\t%s\t%s\n' "$action" "$repo/$src" "$dest" "$opts"
    done
}

# -------- filesystem helpers -------------------------------------------------
_wt_has_opt() { [[ ",$2," == *",$1,"* ]]; }  # needle, csv
_wt_ensure_parent() { mkdir -p "$(dirname "$1")"; }

# portable directory copy
_wt_copy_tree() {
  local src="$1" dst="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src"/ "$dst"/
  else
    mkdir -p "$dst"
    cp -Rp "$src"/. "$dst"/
  fi
}

_wt_copy_item() { # abs_src abs_dst csv_opts
  local src="$1" dst="$2" opts="$3"
  _wt_has_opt mkdirs "$opts" && _wt_ensure_parent "$dst"
  if [[ -e "$dst" || -L "$dst" ]]; then
    if   _wt_has_opt if-missing "$opts"; then return 0
    elif _wt_has_opt force "$opts";      then rm -rf -- "$dst"
    else _wt_die "Destination exists: $dst (use opts: force | if-missing)"; return 1; fi
  fi
  if [[ -d "$src" ]]; then _wt_copy_tree "$src" "$dst"; else cp -p "$src" "$dst"; fi
}

_wt_symlink_item_abs() { # abs_src_target abs_dst csv_opts
  local target="$1" dst="$2" opts="$3"
  _wt_has_opt mkdirs "$opts" && _wt_ensure_parent "$dst"
  if [[ -e "$dst" || -L "$dst" ]]; then
    if   _wt_has_opt if-missing "$opts"; then return 0
    elif _wt_has_opt force "$opts";      then rm -rf -- "$dst"
    else _wt_die "Destination exists: $dst (use opts: force | if-missing)"; return 1; fi
  fi
  ln -s "$target" "$dst"
}

# -------- worktree plumbing --------------------------------------------------
_wt_branch_exists_local() { git show-ref --verify --quiet "refs/heads/$1"; }
_wt_worktrees_root() { local r; r="$(_wt_cfg_root_abs)" || return 1; printf '%s' "$r"; }
_wt_worktree_dir_for() { printf '%s/%s' "$(_wt_worktrees_root)" "$(_wt_sanitize_branch "$1")"; }
_wt_ensure_root_dir() { mkdir -p "$(_wt_worktrees_root)"; }

_wt_apply_rules_into() { # worktree_dir
  local wt="$1" action abs_src dest_rel opts
  _wt_cfg_rules_tsv | while IFS=$'\t' read -r action abs_src dest_rel opts; do
    if [[ ! -e "$abs_src" && ! -L "$abs_src" ]]; then
      if _wt_has_opt optional "$opts"; then _wt_log "optional missing: ${abs_src#"$(_wt_git_root)"/}"; continue
      else _wt_die "Source not found: ${abs_src#"$(_wt_git_root)"/}"; return 1; fi
    fi
    case "$action" in
      copy)    _wt_copy_item        "$abs_src" "$wt/$dest_rel" "$opts" || return 1 ;;
      symlink) _wt_symlink_item_abs "$abs_src" "$wt/$dest_rel" "$opts" || return 1 ;;
      *)       _wt_die "Unknown action in .workspaces: $action"; return 1 ;;
    esac
  done
}

_wt_create_worktree() { # branch [base]
  _wt_need git || return 1; _wt_need yq || return 1
  local branch="$1" base="${2:-}" dir
  _wt_ensure_root_dir
  dir="$(_wt_worktree_dir_for "$branch")"
  [[ -e "$dir" ]] && { _wt_die "Worktree path already exists: $dir"; return 1; }

  if [[ -z "$base" ]]; then
    base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
    [[ -z "$base" ]] && base="HEAD"
  fi

  if _wt_branch_exists_local "$branch"; then
    _wt_log "Adding worktree: $dir  [branch: $branch]"
    git worktree add "$dir" "$branch" >/dev/null || return 1
  else
    _wt_log "Adding worktree: $dir  [new branch: $branch, base: $base]"
    git worktree add -b "$branch" "$dir" "$base" >/dev/null || return 1
  fi

  _wt_apply_rules_into "$dir" || return 1

  local post; post="$(_wt_cfg_post_create || true)"
  if [[ -n "${post:-}" ]]; then ( cd "$dir" && _wt_log "post_create: $post" && eval "$post" ) || return 1; fi

  printf '%s\n' "$dir"
}

_wt_switch_worktree() { # branch
  _wt_need git || return 1; _wt_need yq || return 1
  local branch="$1" dir
  dir="$(_wt_worktree_dir_for "$branch")" || return 1
  if [[ ! -d "$dir" ]]; then
    _wt_create_worktree "$branch" >/dev/null || return 1
  fi

  if _wt_branch_exists_local "$branch"; then
    git -C "$dir" checkout "$branch" >/dev/null || return 1
  else
    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$dir" checkout -b "$branch" "origin/$branch" >/dev/null || return 1
    else
      git -C "$dir" checkout -b "$branch" >/dev/null || return 1
    fi
  fi

  _wt_apply_rules_into "$dir" || return 1

  local post; post="$(_wt_cfg_post_create || true)"
  if [[ -n "${post:-}" ]]; then ( cd "$dir" && _wt_log "post_create: $post" && eval "$post" ) || return 1; fi

  cd "$dir" || return 1
  pwd
}

_wt_list() {
  git worktree list --porcelain | awk '
    $1=="worktree"{dir=$2}
    $1=="branch"{br=$2; gsub("refs/heads/","",br); printf "%-70s [%s]\n", dir, br}
  '
}

# -------- confirmation + delete helpers -------------------------------------
# Honors --yes flag (per-command) and env WT_YES=1
_wt_should_delete() { # $1=human_label $2=path
  local label="$1" path="$2"
  if [[ "${_WT_YES:-}" = "1" || "${WT_YES:-}" = "1" ]]; then
    return 0
  fi
  printf '[wt] About to delete %s\n[wt] Path: %s\n' "$label" "$path" >&2
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) _wt_log "Aborted."; return 1 ;;
  esac
}

_wt_delete_dir() { # $1=dir (rm -rf)
  local dir="$1"
  rm -rf -- "$dir"
}

# -------- commands with confirmation ----------------------------------------
_wt_remove() { # [--yes] branch
  local yes=0
  if [[ "${1:-}" == "--yes" ]]; then yes=1; shift; fi
  local branch="$1" dir
  [[ -n "$branch" ]] || { _wt_die "Usage: wt remove [--yes] <branch>"; return 1; }
  dir="$(_wt_worktree_dir_for "$branch")" || return 1
  [[ -d "$dir" ]] || { _wt_die "No worktree directory for branch: $branch ($dir)"; return 1; }

  _WT_YES="$yes"
  _wt_should_delete "worktree for branch \"$branch\"" "$dir" || return 1
  _wt_log "Removing worktree: $dir"
  git worktree remove "$dir"
}

_wt_prune_all() { # [--yes]
  local yes=0
  if [[ "${1:-}" == "--yes" ]]; then yes=1; shift; fi

  local root; root="$(_wt_worktrees_root)" || return 1
  [[ -d "$root" ]] || { _wt_log "Nothing to prune (no root dir: $root)"; git worktree prune; return 0; }

  local tmp; tmp="$(mktemp)"
  git worktree list --porcelain | awk '$1=="worktree"{print $2}' >"$tmp"

  local d
  shopt -s nullglob
  for d in "$root"/*; do
    [[ -d "$d" ]] || continue
    if ! grep -qx -- "$d" "$tmp"; then
      _WT_YES="$yes"
      _wt_should_delete "unregistered directory" "$d" || { _wt_log "Skipped: $d"; continue; }
      _wt_log "Deleting unregistered directory: $d"
      _wt_delete_dir "$d"
    fi
  done
  rm -f "$tmp"
  git worktree prune
}

# -------- init: create starter .workspaces ----------------------------------
_wt_init() { # [--force]
  _wt_need git || return 1; _wt_need yq || return 1
  local cfg; cfg="$(_wt_cfg_path)" || return 1
  local force=0
  if [[ "${1:-}" == "--force" ]]; then force=1; shift; fi
  if [[ -f "$cfg" && $force -ne 1 ]]; then
    _wt_die "Config already exists: $cfg (use 'wt init --force' to overwrite)"
    return 1
  fi

  local repo; repo="$(_wt_git_root)" || return 1
  cat > "$cfg" <<'YAML'
# wt config (YAML) — stored at .workspaces (no extension)
# root: ../<repo>-worktrees   # uncomment to override default location
post_create: ""               # e.g., "npm ci"

rules:
  # Share your .env file across all worktrees (if present in repo root)
  - action: symlink
    src: .env
    dest: .env
    opts: [optional, if-missing]

  # Share node_modules across all worktrees (use with care)
  - action: symlink
    src: node_modules
    dest: node_modules
    opts: [optional, mkdirs, if-missing]
YAML

  _wt_log "Wrote starter config: $cfg"
  _wt_log "Edit 'post_create' or add more rules as needed."
}

_wt_usage() {
  cat <<'EOF'
Usage:
  wt init [--force]               Create a starter .workspaces config (symlink .env & node_modules)
  wt new <branch> [<base-ref>]    Create a new worktree and apply .workspaces rules
  wt switch <branch>              Create if needed, checkout, apply rules, cd into it
  wt remove [--yes] <branch>      Remove the worktree for branch (with confirmation)
  wt prune --all [--yes]          Prompt to delete each unregistered ROOT/* dir; then git worktree prune
  wt list                         List registered worktrees
  wt help                         Show this help

Config (.workspaces in repo root, YAML; optional):
  root: ../<repo>-worktrees
  post_create: npm ci
  rules:
    - action: copy|symlink
      src:  RELATIVE/TO/REPO
      dest: RELATIVE/TO/WORKTREE
      opts: [if-missing, mkdirs, force, optional]

Flags:
  --yes       Skip confirmation prompts for destructive ops (remove, prune)
  --force     Overwrite existing .workspaces in 'wt init'
Env:
  WT_YES=1    Global non-interactive mode (same as providing --yes)
EOF
}

# -------- user-facing dispatcher -------------------------------------------
wt() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init)    _wt_init "${1:-}" ;;
    new)     [[ $# -ge 1 ]] || { _wt_usage; return 1; }
             _wt_create_worktree "$1" "${2:-}" ;;
    switch)  [[ $# -eq 1 ]] || { _wt_usage; return 1; }
             _wt_switch_worktree "$1" ;;
    remove)  _wt_remove "$@" ;;
    prune)   if [[ "${1:-}" != "--all" ]]; then _wt_usage; return 1; fi
             shift; _wt_prune_all "${1:-}" ;;
    list)    _wt_list ;;
    help|-h|--help|"") _wt_usage ;;
    *)       _wt_die "Unknown command: $cmd (see: wt help)"; return 1 ;;
  esac
}