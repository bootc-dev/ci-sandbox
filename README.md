# ci-sandbox

A sandbox repository for testing GitHub Actions CI workflow patterns.

## Workflow Design

- **Fast jobs** (`validate`, `cargo-deny`, `install-tests`, `docs`): Run on every PR
- **Heavy jobs** (`package`, `test-integration`, `test-upgrade`, `test-container-export`): Only run in merge queue or when `ci-full` label is applied
- **`required-checks`**: Sentinel job that accepts `skipped` as success
- **`compute-ci-level`**: Outputs `full=true/false` to control heavy jobs
