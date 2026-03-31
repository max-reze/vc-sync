# Bidirectional Git-SVN Sync Script

## Context

The project lives in both Git and SVN. Team 1 works exclusively in Git. Team 2 works in SVN and is responsible for performing sync in both directions. Sync is manual/on-demand.

Sync commands do NOT auto-commit. Team 2 reviews the changes before committing.

## How it works

Uses `rsync` to copy files between git and SVN directories. rsync handles new and modified files via mtime+size comparison. Deletes are handled by `rsync --delete` plus VCS bookkeeping (`svn add`/`svn delete` or `git add -A`).

No checksumming, no snapshots, no manifests — just rsync. Typical sync completes in ~0.1s for 500 files.

## Directory layout

```
sync.sh                # Main script
.sync/
  config               # Paths to git and SVN dirs, remote URLs, branch
  sync.log             # Append-only operation log
```

The git and SVN directories can live anywhere on disk — paths are stored in `.sync/config`.

## Setup

Point `sync.sh` at existing git and SVN working copies:

```bash
./sync.sh init --git-dir /path/to/git-repo --svn-dir /path/to/svn-wc
```

Remote URLs and branch are auto-detected. If the directories are named `git-repo/` and `svn-wc/` and sit next to `sync.sh`, they are auto-detected too:

```bash
./sync.sh init
```

## Commands

| Command | What it does |
|---|---|
| `./sync.sh init --git-dir <path> --svn-dir <path>` | Initialize from existing directories |
| `./sync.sh status` | Dry-run showing what would be synced in each direction |
| `./sync.sh pull-git` | Pull latest from git remote |
| `./sync.sh git2svn` | Copy git changes into SVN dir (no commit) |
| `./sync.sh svn2git` | Copy SVN changes into git dir (no commit) |

## Workflows

### Git to SVN (Team 1 made changes)

```bash
./sync.sh pull-git
./sync.sh git2svn
cd <svn-dir> && svn diff && svn commit -m "Sync from git"
```

### SVN to git (Team 2 made changes)

```bash
./sync.sh svn2git
cd <git-dir> && git diff && git add -A && git commit -m "Sync from SVN"
git push origin main
```

## SVN-only directories

Directories listed in `SVN_ONLY_DIRS` at the top of `sync.sh` are excluded from all sync operations. These dirs exist in SVN but are not needed in git.

Current exclusions:
- `exdir1`
- `exdir2/path1`

To modify, edit the `SVN_ONLY_DIRS` array in `sync.sh`.

## Known limitations

- **Empty directories**: git doesn't track them; `rsync --delete` may remove empty SVN dirs
- **SVN properties** (`svn:executable`, etc.): only the executable bit is preserved
- **Renames**: appear as delete + add
- **No conflict detection**: the last sync direction wins. Use `./sync.sh status` before syncing to see what would change
