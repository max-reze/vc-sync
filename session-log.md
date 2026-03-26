# Session Log — 2026-03-26

## Goal

Design and implement a bidirectional sync tool for a project that lives in both Git and SVN.

## Conversation

### User message 1

> we need to work with the same project in to different version controls - git and svn.
> how would you go about syncing project dir (we need both directions) ?

### Assistant response 1

Asked three clarifying questions about workflow, sync frequency, and history preservation.

### User answers 1

- **Workflow**: "Both are active" — different people/teams commit to Git and SVN independently
- **Sync frequency**: "Manual / on-demand" — a developer triggers the sync when needed
- **History preservation**: "Squash is fine" — bulk sync commits are acceptable

### Assistant response 2

Explored approaches (git-svn, SubGit, rsync-based, custom script). Drafted initial plan and presented for approval.

### User feedback on plan (plan revision 1)

> Good direction. But, there are few more points to consider:
> - Team 1 is going to only use git
> - Team 2 uses svn and is responsible to perform the sync
> - sync commands should not perform commits, since Team 2 has to review first.

### Assistant response 3

Updated the plan with the three additional constraints: Team 2 drives the sync, no auto-commits, review before committing. Presented revised plan for approval.

### User response 3

Approved the plan (with no further edits).

### Assistant response 4

Implemented `sync.sh`, tested manifest generation and conflict detection.

### User message 4

> pls add the executed plan as plan.md to the project folder

### Assistant response 5

Copied plan to `plan.md`.

### User message 5

> pls write this session log into the project folder as .md file

### Assistant response 6

Created `session-log.md`.

### User message 6

> pls also include user inputs

### Assistant response 7

Updated `session-log.md` with full user inputs (this version).

---

## Requirements Summary

**Initial request**: Sync a project directory between Git and SVN in both directions.

**Clarifying questions and answers**:

1. **Workflow** — Who commits where?
   - Answer: Both VCSes are active (different teams)

2. **Sync frequency** — How often?
   - Answer: Manual / on-demand

3. **History preservation** — Preserve individual commits or squash?
   - Answer: Squash is fine

**Additional constraints from user review**:
- Team 1 uses only Git
- Team 2 uses SVN and is responsible for performing the sync
- Sync commands must NOT auto-commit — Team 2 reviews changes first

## Approach Evaluation

Considered four approaches:

| Approach | Verdict |
|---|---|
| `git-svn` bridge | Rejected — rewrites commit hashes, fragile with merge commits, assumes single bridge operator |
| SubGit (commercial) | Rejected — requires server-side install, continuous sync (overkill for manual use) |
| rsync-based script | Selected — simple, predictable, debuggable |
| Custom sync from scratch | Partially adopted — added snapshot-based conflict detection on top of rsync |

**Final approach**: rsync for file copying + checksum manifest snapshots for three-way conflict detection.

## Implementation

Created `sync.sh` (~300 lines bash) with the following subcommands:

| Command | Description |
|---|---|
| `init <git-url> <svn-url>` | One-time setup: clone git, checkout svn, take initial snapshot |
| `status` | Show changes on both sides since last sync (read-only) |
| `pull-git` | Fetch latest from git remote |
| `git2svn [--force\|--skip-conflicts]` | Copy git changes into svn-wc (no commit) |
| `svn2git [--force\|--skip-conflicts]` | Copy svn changes into git-repo (no commit) |
| `snapshot` | Record current state as new baseline (run after manual commit) |

### Core mechanism

1. **Manifest generation** — sorted list of `(path|md5|mode|size)` per directory
2. **Three-way diff** — compare both sides against snapshot baseline to classify each file
3. **Conflict gate** — abort on conflicts by default; `--force` or `--skip-conflicts` to override
4. **rsync copy** — `rsync -av --delete` with VCS metadata excluded
5. **No auto-commit** — script stops after copying, prints review instructions
6. **Snapshot update** — separate step after Team 2 manually commits

### Key design decisions

- Git and SVN repos live as **sibling directories** (`git-repo/`, `svn-wc/`), completely independent
- Snapshot stores both a manifest and full file copies (for `diff3` conflict resolution)
- `svn add`/`svn delete` are handled automatically after rsync for new/missing files
- Conflict on "deleted on source + modified on destination" is treated as conflict, not auto-deleted

## Testing

- Verified script syntax (`bash -n`)
- Verified help output
- Tested manifest generation with mock directories — correct `path|md5|mode|size` output
- Tested conflict detection with simulated scenario:
  - File unchanged on both sides — not reported
  - File changed only on git side — reported as `GIT-MODIFIED`
  - File added only on git side — reported as `GIT-ADDED`
  - File changed on both sides — reported as `CONFLICT`
  - All counts correct in summary line

## Files Created

- `sync.sh` — the sync script (executable)
- `plan.md` — the implementation plan
- `session-log.md` — this file
