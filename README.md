# merge-queue-like-bors

A demonstration of running GitHub's merge queue like [bors](https://github.com/rust-lang/bors): expensive CI only runs once, on the tip of the queue batch.

AI note: This project and text has substantial generation from AI, but has been
reviewed by @cgwalters.

## The problem

[Bors](https://github.com/rust-lang/bors) was created to solve a simple problem:
ensuring that tip-of-tree is always green (solving the "PR 1 and 2 pass independently,
but break when merged together problem).

It also implements "CI batching", running expensive CI jobs on multiple PRs
at once and merging them together.

Later, Github added merge queues, but merge queues run *all* tests on each PR,
so if you have expensive CI, it adds up quickly.

## The insight

In a merge queue run, we can detect the "tip" commit that rolls in all
the other changes, and run expensive CI jobs just on that one.

Then we get all the benefits of bors-like batching with no external bot.

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

## The workflow

See [`.github/workflows/ci.yml`](.github/workflows/ci.yml) for the full
annotated example. The critical section is the `merge_group` branch of
`compute-ci-level`.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.
