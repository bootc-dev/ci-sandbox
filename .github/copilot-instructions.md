# Copilot / AI agent instructions for bootc

This project is part of the [CNCF](https://cncf.io) and uses
[GitHub Copilot Enterprise](https://contribute.cncf.io/blog/2025/12/16/github-copilot-enterprise-for-maintainers/)
sponsored for CNCF maintainers.

## Project overview

`bootc` is a Rust project providing image-based Linux OS updates using OCI/container
tooling.  It runs as a privileged system daemon and calls out to ostree (C) and
containers/image (Go) under the hood.

## Repository layout

- `crates/lib/` — main library crate (public API lives here)
- `crates/host-utils/` — utilities for host-system interactions
- `ci/` — CI scripts and helper tooling
- `docs/` — user-facing documentation (mdBook)
- `tests/` — integration tests (tmt / FMF based)
- `.github/workflows/` — GitHub Actions CI/CD

## Build and test

```bash
# Build
cargo build

# Run unit tests
cargo nextest run

# Build the container image from current source
just build

# Format
cargo fmt --check

# Lint
cargo clippy -- -D warnings
```

The devcontainer (`ghcr.io/bootc-dev/devenv-c10s`) has all required tooling
pre-installed including Rust, Go, podman, `gh` CLI, `opencode`, `goose`, and `just`.

## Key conventions

- All code must be formatted with `rustfmt` and pass `cargo clippy`.
- Public API changes require a changelog entry and must not break semver.
- Commits must follow Conventional Commits (`feat:`, `fix:`, `ci:`, `docs:`, etc.).
- Do NOT add `Signed-off-by` lines to AI-generated commits; only humans sign off.
- Include `Assisted-by: <tool> (<model>)` in commit messages for AI-generated code.
- Branch protection is enforced on `main`; all changes go through PRs with CI.

## AI-specific guidance

When writing or reviewing code:

1. Prefer small, surgical diffs over large refactors unless explicitly asked.
2. Test coverage is required for new logic; use `cargo nextest` patterns.
3. Avoid pulling in new dependencies without discussion; check `deny.toml`.
4. For CLI changes, preserve existing output format unless breaking it is intentional.
5. Security-sensitive code (privilege escalation, filesystem operations) needs
   extra care — comment your assumptions and handle all error paths.
6. This project runs as root on real systems; avoid `unwrap()` in non-test code.

## Agentic workflows

The repo ships an agentic CI monitor workflow (`.github/workflows/agentic-ci-monitor.yml`)
that uses `opencode` inside the `devenv-c10s` container to summarise recent CI
failures and open a PR.  Trigger it manually via `workflow_dispatch`.
