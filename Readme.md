# Bidirectional Git-SVN Sync Script

## Context

The project lives in both Git and SVN. Team 1 works exclusively in Git. Team 2 works in SVN and is responsible for performing sync in both directions. Sync is manual/on-demand, and squash commits are acceptable.

**Key constraint**: Sync commands must NOT auto-commit. Team 2 reviews the synced changes before committing to either VCS themselves.

## Approach: rsync + snapshot-based conflict detection

Keep Git and SVN as **completely separate, normal repositories** in sibling directories. Use `rsync` for file copying and a **checksum manifest snapshot** to detect conflicts (files changed on both sides since last sync).

## Directory layout

```
test_20260326c/
  sync.sh              # Main script (the deliverable)
  git-repo/            # Git clone (Team 2 maintains this as a local mirror)
  svn-wc/              # SVN working copy (Team 2's primary workspace)
  .sync/
    snapshot/
      manifest.txt     # Checksums from last successful sync
      files/           # Full file copy for 3-way conflict resolution
    config             # Remote URLs, branch, excludes
    sync.log           # Append-only operation log
```

## Script subcommands

| Command | What it does |
|---|---|
| `./sync.sh init <git-url> <svn-url>` | Clone git, checkout svn, take initial snapshot |
| `./sync.sh status` | Show what changed on each side since last sync (read-only) |
| `./sync.sh pull-git` | Pull latest from git remote into `git-repo/` |
| `./sync.sh git2svn [--force\|--skip-conflicts]` | Copy git changes into `svn-wc/` — does NOT commit. Team 2 reviews, then runs `svn commit` manually |
| `./sync.sh svn2git [--force\|--skip-conflicts]` | Copy svn changes into `git-repo/` — does NOT commit. Team 2 reviews, then runs `git add/commit/push` manually |
| `./sync.sh snapshot` | Record current state as the new baseline (run after manual commit succeeds) |

## Typical workflows

### Pulling git changes into SVN (Team 1 made changes)

```bash
./sync.sh pull-git              # fetch latest from git remote
./sync.sh status                # see what changed on each side
./sync.sh git2svn               # copy files into svn-wc (no commit)
cd svn-wc && svn diff            # Team 2 reviews
svn commit -m "Sync from git"   # Team 2 commits when satisfied
cd .. && ./sync.sh snapshot      # record new baseline
```

### Pushing SVN changes to git (Team 2 made changes)

```bash
./sync.sh pull-git              # make sure git-repo is up to date
./sync.sh status                # see what changed
./sync.sh svn2git               # copy files into git-repo (no commit)
cd git-repo && git diff          # Team 2 reviews
git add -A && git commit -m "Sync from SVN"
git push origin main
cd .. && ./sync.sh snapshot      # record new baseline
```

## Core mechanism

1. **Manifest generation** — For each directory, produce a sorted list of `(path|md5|mode|size)` tuples, excluding `.git`, `.svn`, `.sync`.
2. **Three-way diff** — Compare git manifest and svn manifest each against the snapshot manifest to classify every file as: unchanged / modified-one-side / modified-both (CONFLICT) / added / deleted.
3. **Conflict gate** — If files changed on both sides, abort by default. Offer `--force` (source wins) or `--skip-conflicts` (sync everything except conflicts).
4. **rsync copy** — `rsync -av --delete --exclude={.git,.svn,.sync}` from source to destination.
5. **NO auto-commit** — Script stops after copying files. Prints a summary of what changed and reminds the user to review and commit manually.
6. **Snapshot update** — Separate `snapshot` subcommand, run by Team 2 after they've committed. This records the new baseline.

## Conflict resolution

- **Modified on both sides**: script prints the conflicting files and paths to all three versions (snapshot baseline in `.sync/snapshot/files/`, git version, svn version) so the developer can use `diff3` or any merge tool.
- **Deleted on source, modified on destination**: treated as conflict, not auto-deleted.
- **Added on both sides with identical content**: auto-resolved silently.

## Known limitations & edge cases

- **Line endings**: manifest uses raw bytes for checksums; conflict report notes when only line endings differ
- **Empty directories**: git doesn't track them, so `rsync --delete` may remove empty SVN dirs
- **SVN properties** (`svn:executable`, etc.): only the executable bit is preserved via `rsync -p`
- **Renames**: appear as delete + add (acceptable given squash commits)
- **Snapshot must be taken after commit**: if Team 2 forgets `./sync.sh snapshot`, the next sync will see stale baselines and may report false conflicts. The script should warn if the snapshot is older than the latest commit on either side.

## Files to create

1. **`sync.sh`** (~350 lines bash) — all subcommands, manifest generation, conflict detection, rsync invocation, status reporting
2. **`.sync/config`** — created by `init`, holds git remote, svn URL, branch, exclude patterns

## Verification

1. `./sync.sh init <git-url> <svn-url>` — confirm both repos are cloned/checked out and initial snapshot exists
2. Make a change in git-repo, commit & push. Run `./sync.sh pull-git && ./sync.sh status` — see the change listed
3. `./sync.sh git2svn` — confirm file is copied into svn-wc but NOT committed. `svn status` shows it as modified
4. Manually `svn commit`, then `./sync.sh snapshot`
5. Make a change in svn-wc, commit. Run `./sync.sh svn2git` — confirm file is copied into git-repo but NOT committed. `git status` shows it as modified
6. Manually `git add/commit/push`, then `./sync.sh snapshot`
7. Make conflicting changes on both sides — confirm sync aborts and reports conflicts with paths to all three versions
