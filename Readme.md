# Bidirectional Git-SVN Sync Script

## Context

The project lives in both Git and SVN. Team 1 works exclusively in Git. Team 2 works in SVN and is responsible for performing sync in both directions. Sync is manual/on-demand, and squash commits are acceptable.

**Key constraint**: Sync commands must NOT auto-commit. Team 2 reviews the synced changes before committing to either VCS themselves.

## Approach: rsync + snapshot-based conflict detection

Keep Git and SVN as **completely separate, normal repositories**. Use `rsync` for file copying and a **checksum manifest snapshot** to detect conflicts (files changed on both sides since last sync).

## Directory layout

```
sync.sh                # Main script
.sync/
  snapshot/
    manifest.txt       # Checksums from last successful sync
    files/             # Full file copy for 3-way conflict resolution
  config               # Paths, remote URLs, branch
  sync.log             # Append-only operation log
```

The git and SVN directories can live anywhere on disk — paths are stored in `.sync/config`.

## Setup

### From existing directories (already cloned/checked out)

```bash
./sync.sh init --git-dir /path/to/git-repo --svn-dir /path/to/svn-wc
```

Remote URLs and branch are auto-detected from the repos. Override if needed:

```bash
./sync.sh init --git-dir /path/to/git-repo --svn-dir /path/to/svn-wc \
  --git-url git@github.com:org/project.git --git-branch main
```

### From URLs (fresh clone/checkout)

```bash
./sync.sh init --git-url git@github.com:org/project.git --svn-url https://svn.example.com/trunk
```

Repos are cloned into `git-repo/` and `svn-wc/` next to `sync.sh`.

### Mix (one exists, clone the other)

```bash
./sync.sh init --git-dir /path/to/git-repo --svn-url https://svn.example.com/trunk
```

## Commands

| Command | What it does |
|---|---|
| `./sync.sh init [options]` | Initialize sync environment (see `init --help`) |
| `./sync.sh status` | Show what changed on each side since last sync (read-only) |
| `./sync.sh pull-git` | Pull latest from git remote |
| `./sync.sh git2svn [--force\|--skip-conflicts]` | Copy git changes into SVN dir — does NOT commit |
| `./sync.sh svn2git [--force\|--skip-conflicts]` | Copy SVN changes into git dir — does NOT commit |
| `./sync.sh snapshot` | Record current state as new baseline (run after manual commit) |

## Typical workflows

### Pulling git changes into SVN (Team 1 made changes)

```bash
./sync.sh pull-git              # fetch latest from git remote
./sync.sh status                # see what changed on each side
./sync.sh git2svn               # copy files into SVN dir (no commit)
cd /path/to/svn-wc && svn diff  # Team 2 reviews
svn commit -m "Sync from git"   # Team 2 commits when satisfied
cd /path/to/sync && ./sync.sh snapshot  # record new baseline
```

### Pushing SVN changes to git (Team 2 made changes)

```bash
./sync.sh pull-git              # make sure git is up to date
./sync.sh status                # see what changed
./sync.sh svn2git               # copy files into git dir (no commit)
cd /path/to/git-repo && git diff          # Team 2 reviews
git add -A && git commit -m "Sync from SVN"
git push origin main
cd /path/to/sync && ./sync.sh snapshot    # record new baseline
```

## SVN-only directories

Directories listed in `SVN_ONLY_DIRS` at the top of `sync.sh` are excluded from all sync operations. These dirs exist in SVN but are not needed in git.

Current exclusions:
- `exdir1`
- `exdir2/path1`

To modify, edit the `SVN_ONLY_DIRS` array in `sync.sh`.

## Conflict resolution

- **Modified on both sides**: script prints the conflicting files and paths to all three versions (snapshot baseline in `.sync/snapshot/files/`, git version, SVN version) so the developer can use `diff3` or any merge tool.
- **Deleted on source, modified on destination**: treated as conflict, not auto-deleted.
- **Added on both sides with identical content**: auto-resolved silently.

Conflict flags:
- `--force` — source side wins for all conflicts
- `--skip-conflicts` — sync everything except conflicting files

## Core mechanism

1. **Manifest generation** — sorted list of `(path|md5|mode|size)` per directory, excluding `.git`, `.svn`, `.sync`, and SVN-only dirs.
2. **Three-way diff** — compare both sides against the snapshot manifest to classify each file as: unchanged / modified-one-side / modified-both (CONFLICT) / added / deleted.
3. **Conflict gate** — abort on conflicts by default.
4. **rsync copy** — `rsync -av --delete` with VCS metadata and SVN-only dirs excluded.
5. **No auto-commit** — script stops after copying files, prints review instructions.
6. **Snapshot update** — separate `snapshot` command, run after manual commit.

## Known limitations

- **Line endings**: manifest uses raw bytes for checksums; phantom conflicts possible if git/SVN normalize differently
- **Empty directories**: git doesn't track them; `rsync --delete` may remove empty SVN dirs
- **SVN properties** (`svn:executable`, etc.): only the executable bit is preserved
- **Renames**: appear as delete + add (acceptable given squash commits)
- **Snapshot must be taken after commit**: forgetting `./sync.sh snapshot` causes stale baselines and false conflicts on next sync
