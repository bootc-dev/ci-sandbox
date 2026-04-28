# merge-queue-like-bors

A demonstration of running GitHub's merge queue like [bors](https://github.com/rust-lang/bors): expensive CI only runs once, on the tip of the queue batch.

## The problem

GitHub's merge queue runs a full CI suite for every PR in the queue, stacked on
the ones ahead of it. With 4 PRs queued and a 3-hour CI suite, you burn 12 hours
of compute for what should be a single 3-hour run.

[Bors](https://github.com/rust-lang/bors) solves this by serializing all merges
through a single staging branch (`automation/bors/auto`). Approved PRs accumulate,
then bors runs CI once on the batch, and fast-forwards main if it passes.

## The insight

GitHub's merge queue already stacks PRs in order — each queue entry's commit
includes all prior entries' changes. The last entry (the *tip*) therefore tests
the entire batch. If you run expensive jobs only on the tip and skip them for
earlier entries, you get bors-like batching with no external bot.

The tip can be identified at CI runtime by querying the GraphQL API:

```graphql
{
  repository(owner: "...", name: "...") {
    mergeQueue(branch: "main") {
      entries(last: 1) {
        nodes { headCommit { oid } }
      }
    }
  }
}
```

Compare the returned OID to `$GITHUB_SHA`. If they match, you are the tip.

## Requirements

**This only works with ALLGREEN grouping** (GitHub's "Group pull requests" merge
queue setting). Under ALLGREEN, GitHub waits for *all* queue entries to pass
required checks before merging the group. Non-tip entries finish quickly (cheap
tests only) and wait; the tip runs the full suite; when it passes, everything
merges together.

Under HEADMERGE ("Merge independently"), each PR merges the moment it
individually passes — so non-tip entries would merge having only passed cheap
tests, defeating the purpose entirely.

## How it works in the workflow

The `compute-ci-level` job detects its queue position and sets `run_heavy`
accordingly. All downstream expensive jobs are gated on `run_heavy == 'true'`.

```
merge_group event fires for each queue entry
        │
        ▼
compute-ci-level
  ├─ query mergeQueue(last: 1).headCommit.oid
  ├─ compare to $GITHUB_SHA
  ├─ if match (or API failure): run_heavy=true
  └─ if no match: run_heavy=false
        │
        ├─ validate, docs, cargo-deny   ← always run (cheap, ~minutes)
        │
        └─ [if run_heavy]
           ├─ package matrix
           ├─ test-integration matrix   ← expensive, hours
           ├─ test-upgrade matrix
           └─ test-container-export
```

With 4 PRs in the queue:

```
PR #1  [not tip]: validate ✓  docs ✓  cargo-deny ✓  integration: skipped  → done in 2min
PR #2  [not tip]: validate ✓  docs ✓  cargo-deny ✓  integration: skipped  → done in 2min
PR #3  [not tip]: validate ✓  docs ✓  cargo-deny ✓  integration: skipped  → done in 2min
PR #4  [tip]:     validate ✓  docs ✓  cargo-deny ✓  integration: ✓✓✓...   → done in 3hr
                                                                            ↓
                                                               all 4 PRs merge
```

## Race conditions

All safe:

- **New PR added while tip is running**: the old tip already started the full
  suite. The new PR becomes the new tip and also runs the full suite. You get one
  extra full run during overlap — acceptable.

- **Tip is kicked out of the queue**: GitHub rebuilds the queue with new commits
  (new SHAs). The new tip's CI triggers fresh, detects itself as tip, runs full
  suite. The previous non-tip entries that ran only cheap tests never merge
  (ALLGREEN holds everything until the full suite passes).

## Demonstrated in bootc-dev/ci-sandbox

This approach was prototyped and verified in
[bootc-dev/ci-sandbox](https://github.com/bootc-dev/ci-sandbox). Three PRs were
queued simultaneously:

| Position | SHA | Detected as | run_heavy | Heavy jobs |
|---|---|---|---|---|
| 1 | `1173855b...` | NOT tip | false | skipped |
| 2 | `ef43a37f...` | NOT tip | false | skipped |
| 3 | `4caa126e...` | IS tip | true | ran (37 jobs) |

All three passed `required-checks` and merged together.

## The workflow

See [`.github/workflows/ci.yml`](.github/workflows/ci.yml) for the full
annotated example. The critical section is the `merge_group` branch of
`compute-ci-level`.
