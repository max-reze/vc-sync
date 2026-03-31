#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/.sync"
CONFIG_FILE="$SYNC_DIR/config"
LOG_FILE="$SYNC_DIR/sync.log"

# Defaults — overridden by config after load_config
GIT_REPO="$SCRIPT_DIR/git-repo"
SVN_WC="$SCRIPT_DIR/svn-wc"

RSYNC_EXCLUDES=(--exclude='.git' --exclude='.svn' --exclude='.sync' --exclude='sync.sh')

# Directories that exist in SVN but should NOT be synced to git.
# Also excluded from git2svn so rsync --delete does not remove them.
SVN_ONLY_DIRS=('exdir1' 'exdir2/path1')

# Build rsync exclude flags for SVN-only dirs
SVN_ONLY_EXCLUDES=()
for _d in "${SVN_ONLY_DIRS[@]}"; do
    SVN_ONLY_EXCLUDES+=(--exclude="$_d")
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -d "$SYNC_DIR" ]] && echo "$msg" >> "$LOG_FILE"
}

die() { echo "ERROR: $*" >&2; exit 1; }

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Not initialized. Run: $0 init --git-dir <path> --svn-dir <path>"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    [[ -n "${GIT_DIR:-}" ]] && GIT_REPO="$GIT_DIR"
    [[ -n "${SVN_DIR:-}" ]] && SVN_WC="$SVN_DIR"
    [[ -d "$GIT_REPO" ]] || die "Git directory not found: $GIT_REPO"
    [[ -d "$SVN_WC" ]]   || die "SVN directory not found: $SVN_WC"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
    local git_dir=""
    local svn_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --git-dir) git_dir="$2"; shift 2 ;;
            --svn-dir) svn_dir="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 init --git-dir <path> --svn-dir <path>"
                return 0
                ;;
            *) die "Unknown option: $1. Run '$0 init --help'." ;;
        esac
    done

    # Auto-detect at default paths if not specified
    [[ -z "$git_dir" && -d "$GIT_REPO/.git" ]] && git_dir="$GIT_REPO"
    [[ -z "$svn_dir" && -d "$SVN_WC/.svn" ]]   && svn_dir="$SVN_WC"

    [[ -n "$git_dir" ]] || die "Provide --git-dir. Run '$0 init --help'."
    [[ -n "$svn_dir" ]] || die "Provide --svn-dir. Run '$0 init --help'."
    [[ -d "$git_dir/.git" ]] || die "Not a git repo: $git_dir"
    [[ -d "$svn_dir/.svn" ]] || die "Not an SVN working copy: $svn_dir"

    # Resolve to absolute paths
    git_dir="$(cd "$git_dir" && pwd)"
    svn_dir="$(cd "$svn_dir" && pwd)"

    # Auto-detect remote info
    local git_url git_branch svn_url
    git_url=$(git -C "$git_dir" remote get-url origin 2>/dev/null || echo "")
    git_branch=$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    svn_url=$(svn info "$svn_dir" --show-item url 2>/dev/null || echo "")

    mkdir -p "$SYNC_DIR"

    cat > "$CONFIG_FILE" <<EOF
GIT_DIR="$git_dir"
SVN_DIR="$svn_dir"
GIT_REMOTE="$git_url"
GIT_BRANCH="$git_branch"
SVN_URL="$svn_url"
EOF

    log "Initialized."
    echo "  GIT_DIR=$git_dir"
    echo "  SVN_DIR=$svn_dir"
    echo "  GIT_BRANCH=$git_branch"
}

cmd_status() {
    load_config

    echo "=== Git → SVN (what git2svn would copy) ==="
    rsync -a --dry-run --itemize-changes --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "$GIT_REPO/" "$SVN_WC/" \
    | grep -v '^\.d' || echo "(no changes)"

    echo ""
    echo "=== SVN → Git (what svn2git would copy) ==="
    rsync -a --dry-run --itemize-changes --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "$SVN_WC/" "$GIT_REPO/" \
    | grep -v '^\.d' || echo "(no changes)"
}

cmd_pull_git() {
    load_config
    log "Pulling latest from git remote..."
    git -C "$GIT_REPO" pull origin "$GIT_BRANCH"
    log "Git repo updated."
}

cmd_git2svn() {
    load_config

    log "Syncing git → svn..."
    rsync -av --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "$GIT_REPO/" "$SVN_WC/"

    # SVN bookkeeping: add new, delete missing
    (
        cd "$SVN_WC"
        svn status | grep '^?' | awk '{print $2}' | while IFS= read -r f; do
            svn add --parents "$f"
            echo "  svn add: $f"
        done
        svn status | grep '^!' | awk '{print $2}' | while IFS= read -r f; do
            svn delete "$f"
            echo "  svn delete: $f"
        done
    )

    local git_rev
    git_rev=$(git -C "$GIT_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "git2svn done (git $git_rev)."

    echo ""
    echo "Review:  cd $SVN_WC && svn diff"
    echo "Commit:  cd $SVN_WC && svn commit -m 'Sync from git $git_rev'"
}

cmd_svn2git() {
    load_config

    log "Syncing svn → git..."
    rsync -av --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "$SVN_WC/" "$GIT_REPO/"

    local svn_rev
    svn_rev=$(svn info "$SVN_WC" --show-item revision 2>/dev/null || echo "unknown")
    log "svn2git done (svn r$svn_rev)."

    echo ""
    echo "Review:  cd $GIT_REPO && git diff"
    echo "Commit:  cd $GIT_REPO && git add -A && git commit -m 'Sync from SVN r$svn_rev'"
    echo "Push:    cd $GIT_REPO && git push origin $GIT_BRANCH"
}

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  init --git-dir <path> --svn-dir <path>   Initialize from existing directories
  status                                    Show what would be synced (dry-run)
  pull-git                                  Pull latest from git remote
  git2svn                                   Copy git changes into SVN dir (no commit)
  svn2git                                   Copy SVN changes into git dir (no commit)

Workflow (git → svn):
  ./sync.sh pull-git
  ./sync.sh git2svn
  cd <svn-dir> && svn diff && svn commit -m "Sync from git"

Workflow (svn → git):
  ./sync.sh svn2git
  cd <git-dir> && git diff && git add -A && git commit -m "Sync from SVN"
  git push origin main
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    case "${1:-}" in
        init)     shift; cmd_init "$@" ;;
        status)   cmd_status ;;
        pull-git) cmd_pull_git ;;
        git2svn)  cmd_git2svn ;;
        svn2git)  cmd_svn2git ;;
        -h|--help|"") usage ;;
        *)        die "Unknown command: $1. Run '$0 --help'." ;;
    esac
}

main "$@"
