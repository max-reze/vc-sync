#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/.sync"
SNAPSHOT_DIR="$SYNC_DIR/snapshot"
MANIFEST_FILE="$SNAPSHOT_DIR/manifest.txt"
SNAPSHOT_FILES="$SNAPSHOT_DIR/files"
CONFIG_FILE="$SYNC_DIR/config"
LOG_FILE="$SYNC_DIR/sync.log"
GIT_REPO="$SCRIPT_DIR/git-repo"
SVN_WC="$SCRIPT_DIR/svn-wc"

RSYNC_EXCLUDES=(--exclude='.git' --exclude='.svn' --exclude='.sync' --exclude='sync.sh')

# Directories that exist in SVN but should NOT be synced to git.
# These are also excluded from git2svn so rsync --delete does not remove them.
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
    if [[ -d "$SYNC_DIR" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Not initialized. Run: $0 init <git-url> <svn-url>"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# Generate a manifest for a directory: path|md5|mode|size
# Excludes .git, .svn, .sync, sync.sh, and SVN-only dirs
generate_manifest() {
    local dir="$1"
    local tmpfile
    tmpfile=$(mktemp)

    # Build find exclusions for SVN-only dirs
    local svn_only_find_args=()
    for _d in "${SVN_ONLY_DIRS[@]}"; do
        svn_only_find_args+=(! -path "./${_d}" ! -path "./${_d}/*")
    done

    (
        cd "$dir"
        find . -type f \
            ! -path './.git/*' \
            ! -path './.svn/*' \
            ! -path './.sync/*' \
            ! -name 'sync.sh' \
            "${svn_only_find_args[@]}" \
            -print0 \
        | while IFS= read -r -d '' file; do
            local rel="${file#./}"
            local md5
            md5=$(md5sum "$file" | awk '{print $1}')
            local mode
            mode=$(stat -c '%a' "$file")
            local size
            size=$(stat -c '%s' "$file")
            echo "${rel}|${md5}|${mode}|${size}"
        done
    ) | sort > "$tmpfile"

    echo "$tmpfile"
}

# Compare two manifests against the snapshot manifest.
# Outputs classified changes to stdout.
# Args: $1=source_manifest $2=dest_manifest $3=snapshot_manifest $4=source_label $5=dest_label
classify_changes() {
    local src_manifest="$1"
    local dst_manifest="$2"
    local snap_manifest="$3"
    local src_label="$4"
    local dst_label="$5"

    local src_paths dst_paths snap_paths
    src_paths=$(mktemp)
    dst_paths=$(mktemp)
    snap_paths=$(mktemp)

    # Extract path|md5 pairs
    awk -F'|' '{print $1"|"$2}' "$src_manifest" > "$src_paths"
    awk -F'|' '{print $1"|"$2}' "$dst_manifest" > "$dst_paths"
    if [[ -f "$snap_manifest" ]]; then
        awk -F'|' '{print $1"|"$2}' "$snap_manifest" > "$snap_paths"
    else
        : > "$snap_paths"
    fi

    # Extract just filenames
    local src_files dst_files snap_files
    src_files=$(mktemp)
    dst_files=$(mktemp)
    snap_files=$(mktemp)
    awk -F'|' '{print $1}' "$src_paths" | sort > "$src_files"
    awk -F'|' '{print $1}' "$dst_paths" | sort > "$dst_files"
    awk -F'|' '{print $1}' "$snap_paths" | sort > "$snap_files"

    local conflicts=0
    local src_changes=0
    local dst_changes=0

    # All known files across all three sets
    local all_files
    all_files=$(mktemp)
    sort -u "$src_files" "$dst_files" "$snap_files" > "$all_files"

    while IFS= read -r file; do
        local in_src in_dst in_snap
        in_src=$(grep -cxF "$file" "$src_files" || true)
        in_dst=$(grep -cxF "$file" "$dst_files" || true)
        in_snap=$(grep -cxF "$file" "$snap_files" || true)

        local src_md5 dst_md5 snap_md5
        src_md5=$(grep -F "${file}|" "$src_paths" 2>/dev/null | head -1 | cut -d'|' -f2 || true)
        dst_md5=$(grep -F "${file}|" "$dst_paths" 2>/dev/null | head -1 | cut -d'|' -f2 || true)
        snap_md5=$(grep -F "${file}|" "$snap_paths" 2>/dev/null | head -1 | cut -d'|' -f2 || true)

        # Determine what changed on each side relative to snapshot
        local src_changed=false
        local dst_changed=false

        if [[ "$in_snap" -gt 0 ]]; then
            # File existed in snapshot
            if [[ "$in_src" -gt 0 && "$src_md5" != "$snap_md5" ]]; then src_changed=true; fi
            if [[ "$in_src" -eq 0 ]]; then src_changed=true; fi  # deleted on source
            if [[ "$in_dst" -gt 0 && "$dst_md5" != "$snap_md5" ]]; then dst_changed=true; fi
            if [[ "$in_dst" -eq 0 ]]; then dst_changed=true; fi  # deleted on dest
        else
            # File not in snapshot — new on whichever side(s) have it
            if [[ "$in_src" -gt 0 ]]; then src_changed=true; fi
            if [[ "$in_dst" -gt 0 ]]; then dst_changed=true; fi
        fi

        if $src_changed && $dst_changed; then
            # Both sides changed — check if they converged to the same content
            if [[ "$src_md5" == "$dst_md5" && "$in_src" -gt 0 && "$in_dst" -gt 0 ]]; then
                # Same content on both sides — auto-resolved
                :
            else
                echo "CONFLICT  $file"
                conflicts=$((conflicts + 1))
            fi
        elif $src_changed; then
            if [[ "$in_src" -eq 0 ]]; then
                echo "${src_label}-DELETED  $file"
            elif [[ "$in_snap" -eq 0 ]]; then
                echo "${src_label}-ADDED    $file"
            else
                echo "${src_label}-MODIFIED $file"
            fi
            src_changes=$((src_changes + 1))
        elif $dst_changed; then
            if [[ "$in_dst" -eq 0 ]]; then
                echo "${dst_label}-DELETED  $file"
            elif [[ "$in_snap" -eq 0 ]]; then
                echo "${dst_label}-ADDED    $file"
            else
                echo "${dst_label}-MODIFIED $file"
            fi
            dst_changes=$((dst_changes + 1))
        fi
    done < "$all_files"

    rm -f "$src_paths" "$dst_paths" "$snap_paths" "$src_files" "$dst_files" "$snap_files" "$all_files"

    echo "---"
    echo "SUMMARY: $src_changes ${src_label}-side change(s), $dst_changes ${dst_label}-side change(s), $conflicts conflict(s)"

    return "$conflicts"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
    local git_url="${1:-}"
    local svn_url="${2:-}"
    local git_branch="${3:-main}"

    [[ -n "$git_url" ]] || die "Usage: $0 init <git-url> <svn-url> [git-branch]"
    [[ -n "$svn_url" ]] || die "Usage: $0 init <git-url> <svn-url> [git-branch]"

    mkdir -p "$SYNC_DIR" "$SNAPSHOT_DIR" "$SNAPSHOT_FILES"

    # Write config
    cat > "$CONFIG_FILE" <<EOF
GIT_REMOTE="$git_url"
GIT_BRANCH="$git_branch"
SVN_URL="$svn_url"
EOF

    log "Initializing sync environment..."

    # Clone git repo
    if [[ -d "$GIT_REPO" ]]; then
        log "git-repo/ already exists, pulling latest..."
        git -C "$GIT_REPO" pull origin "$git_branch"
    else
        log "Cloning git repository..."
        git clone -b "$git_branch" "$git_url" "$GIT_REPO"
    fi

    # Checkout SVN working copy
    if [[ -d "$SVN_WC" ]]; then
        log "svn-wc/ already exists, updating..."
        svn update "$SVN_WC"
    else
        log "Checking out SVN working copy..."
        svn checkout "$svn_url" "$SVN_WC"
    fi

    # Take initial snapshot from git-repo (or whichever has content)
    log "Taking initial snapshot..."
    cmd_snapshot

    log "Initialization complete."
    echo ""
    echo "Directory layout:"
    echo "  git-repo/   - Git working tree"
    echo "  svn-wc/     - SVN working copy"
    echo "  .sync/      - Sync metadata"
    echo ""
    echo "Next steps:"
    echo "  ./sync.sh status    - See current state"
    echo "  ./sync.sh git2svn   - Copy git changes into svn-wc"
    echo "  ./sync.sh svn2git   - Copy svn changes into git-repo"
}

cmd_status() {
    load_config

    echo "Generating manifests..."
    local git_manifest svn_manifest
    git_manifest=$(generate_manifest "$GIT_REPO")
    svn_manifest=$(generate_manifest "$SVN_WC")

    echo ""
    echo "Changes since last snapshot:"
    echo "============================"

    # classify_changes returns the conflict count as exit code
    local conflicts=0
    classify_changes "$git_manifest" "$svn_manifest" "$MANIFEST_FILE" "GIT" "SVN" || conflicts=$?

    rm -f "$git_manifest" "$svn_manifest"

    if [[ $conflicts -gt 0 ]]; then
        echo ""
        echo "WARNING: $conflicts conflict(s) detected. Resolve before syncing, or use --force / --skip-conflicts."
    fi
}

cmd_pull_git() {
    load_config

    log "Pulling latest from git remote..."
    git -C "$GIT_REPO" pull origin "$GIT_BRANCH"
    log "Git repo updated."
}

cmd_git2svn() {
    load_config

    local force=false
    local skip_conflicts=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --skip-conflicts) skip_conflicts=true ;;
            *) die "Unknown option: $arg" ;;
        esac
    done

    echo "Generating manifests..."
    local git_manifest svn_manifest
    git_manifest=$(generate_manifest "$GIT_REPO")
    svn_manifest=$(generate_manifest "$SVN_WC")

    echo ""
    echo "Analyzing changes..."

    local change_output conflicts=0
    change_output=$(classify_changes "$git_manifest" "$svn_manifest" "$MANIFEST_FILE" "GIT" "SVN") || conflicts=$?

    echo "$change_output"
    echo ""

    if [[ $conflicts -gt 0 ]]; then
        if $force; then
            echo "WARNING: --force specified. Git version will overwrite SVN for conflicting files."
        elif $skip_conflicts; then
            echo "WARNING: --skip-conflicts specified. Conflicting files will be skipped."
        else
            echo "Conflicts detected. Options:"
            echo "  --force           Git version wins for all conflicts"
            echo "  --skip-conflicts  Skip conflicting files, sync the rest"
            echo ""
            echo "For manual resolution, compare:"
            echo "  Baseline: .sync/snapshot/files/<path>"
            echo "  Git:      git-repo/<path>"
            echo "  SVN:      svn-wc/<path>"
            rm -f "$git_manifest" "$svn_manifest"
            exit 1
        fi
    fi

    # Build exclude list for conflicting files if --skip-conflicts
    local rsync_extra_excludes=()
    if $skip_conflicts && [[ $conflicts -gt 0 ]]; then
        while IFS= read -r line; do
            if [[ "$line" == CONFLICT* ]]; then
                local cfile
                cfile=$(echo "$line" | awk '{print $2}')
                rsync_extra_excludes+=(--exclude="$cfile")
            fi
        done <<< "$change_output"
    fi

    log "Syncing files from git-repo/ to svn-wc/..."
    rsync -av --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "${rsync_extra_excludes[@]}" \
        "$GIT_REPO/" "$SVN_WC/"

    # Handle svn add/delete for new/missing files
    echo ""
    echo "Updating SVN tracking..."
    (
        cd "$SVN_WC"
        # Add unversioned files
        svn status | grep '^?' | awk '{print $2}' | while IFS= read -r f; do
            svn add "$f"
            echo "  svn add: $f"
        done
        # Remove missing files
        svn status | grep '^!' | awk '{print $2}' | while IFS= read -r f; do
            svn delete "$f"
            echo "  svn delete: $f"
        done
    )

    rm -f "$git_manifest" "$svn_manifest"

    local git_rev
    git_rev=$(git -C "$GIT_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "git2svn sync complete (git rev: $git_rev)."

    echo ""
    echo "============================================"
    echo "Files copied to svn-wc/. NOT committed."
    echo ""
    echo "Review the changes:"
    echo "  cd svn-wc && svn diff"
    echo "  cd svn-wc && svn status"
    echo ""
    echo "When satisfied, commit and update snapshot:"
    echo "  cd svn-wc && svn commit -m 'Sync from git $git_rev'"
    echo "  cd .. && ./sync.sh snapshot"
    echo "============================================"
}

cmd_svn2git() {
    load_config

    local force=false
    local skip_conflicts=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --skip-conflicts) skip_conflicts=true ;;
            *) die "Unknown option: $arg" ;;
        esac
    done

    echo "Generating manifests..."
    local git_manifest svn_manifest
    git_manifest=$(generate_manifest "$GIT_REPO")
    svn_manifest=$(generate_manifest "$SVN_WC")

    echo ""
    echo "Analyzing changes..."

    local change_output conflicts=0
    change_output=$(classify_changes "$svn_manifest" "$git_manifest" "$MANIFEST_FILE" "SVN" "GIT") || conflicts=$?

    echo "$change_output"
    echo ""

    if [[ $conflicts -gt 0 ]]; then
        if $force; then
            echo "WARNING: --force specified. SVN version will overwrite git for conflicting files."
        elif $skip_conflicts; then
            echo "WARNING: --skip-conflicts specified. Conflicting files will be skipped."
        else
            echo "Conflicts detected. Options:"
            echo "  --force           SVN version wins for all conflicts"
            echo "  --skip-conflicts  Skip conflicting files, sync the rest"
            echo ""
            echo "For manual resolution, compare:"
            echo "  Baseline: .sync/snapshot/files/<path>"
            echo "  SVN:      svn-wc/<path>"
            echo "  Git:      git-repo/<path>"
            rm -f "$git_manifest" "$svn_manifest"
            exit 1
        fi
    fi

    # Build exclude list for conflicting files if --skip-conflicts
    local rsync_extra_excludes=()
    if $skip_conflicts && [[ $conflicts -gt 0 ]]; then
        while IFS= read -r line; do
            if [[ "$line" == CONFLICT* ]]; then
                local cfile
                cfile=$(echo "$line" | awk '{print $2}')
                rsync_extra_excludes+=(--exclude="$cfile")
            fi
        done <<< "$change_output"
    fi

    log "Syncing files from svn-wc/ to git-repo/..."
    rsync -av --delete \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "${rsync_extra_excludes[@]}" \
        "$SVN_WC/" "$GIT_REPO/"

    rm -f "$git_manifest" "$svn_manifest"

    local svn_rev
    svn_rev=$(svn info "$SVN_WC" --show-item revision 2>/dev/null || echo "unknown")
    log "svn2git sync complete (svn rev: $svn_rev)."

    echo ""
    echo "============================================"
    echo "Files copied to git-repo/. NOT committed."
    echo ""
    echo "Review the changes:"
    echo "  cd git-repo && git diff"
    echo "  cd git-repo && git status"
    echo ""
    echo "When satisfied, commit and push:"
    echo "  cd git-repo && git add -A && git commit -m 'Sync from SVN r$svn_rev'"
    echo "  cd git-repo && git push origin $GIT_BRANCH"
    echo "  cd .. && ./sync.sh snapshot"
    echo "============================================"
}

cmd_snapshot() {
    echo "Taking snapshot of current state..."

    mkdir -p "$SNAPSHOT_DIR" "$SNAPSHOT_FILES"

    # Generate manifests from both sides — they should be identical after a commit
    local git_manifest
    git_manifest=$(generate_manifest "$GIT_REPO")
    cp "$git_manifest" "$MANIFEST_FILE"
    rm -f "$git_manifest"

    # Copy files for 3-way conflict resolution baseline
    rm -rf "${SNAPSHOT_FILES:?}/"*
    rsync -a \
        "${RSYNC_EXCLUDES[@]}" \
        "${SVN_ONLY_EXCLUDES[@]}" \
        "$GIT_REPO/" "$SNAPSHOT_FILES/"

    log "Snapshot updated. $(wc -l < "$MANIFEST_FILE") file(s) recorded."
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  init <git-url> <svn-url> [branch]   Initialize sync environment
  status                               Show changes on both sides since last sync
  pull-git                             Pull latest from git remote
  git2svn [--force|--skip-conflicts]   Copy git changes into svn-wc (no commit)
  svn2git [--force|--skip-conflicts]   Copy svn changes into git-repo (no commit)
  snapshot                             Record current state as new baseline

Typical workflow (git -> svn):
  ./sync.sh pull-git
  ./sync.sh status
  ./sync.sh git2svn
  cd svn-wc && svn diff && svn commit -m "Sync from git"
  cd .. && ./sync.sh snapshot

Typical workflow (svn -> git):
  ./sync.sh pull-git
  ./sync.sh status
  ./sync.sh svn2git
  cd git-repo && git diff && git add -A && git commit -m "Sync from SVN"
  git push origin main
  cd .. && ./sync.sh snapshot
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    case "${1:-}" in
        init)         shift; cmd_init "$@" ;;
        status)       cmd_status ;;
        pull-git)     cmd_pull_git ;;
        git2svn)      shift; cmd_git2svn "$@" ;;
        svn2git)      shift; cmd_svn2git "$@" ;;
        snapshot)     cmd_snapshot ;;
        -h|--help|"") usage ;;
        *)            die "Unknown command: $1. Run '$0 --help' for usage." ;;
    esac
}

main "$@"
