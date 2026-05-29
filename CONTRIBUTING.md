# Contributing to Brewy

Thanks for your interest in improving Brewy! This document captures the workflow and conventions the project follows.

## Requirements

- macOS 15.0 or later (Apple Silicon)
- Xcode 16 or later
- [Homebrew](https://brew.sh) — the app shells out to `brew`
- [`just`](https://github.com/casey/just) for the local task runner (`brew install just`)

Optional tooling used by the checks below: `swiftlint`, `typos-cli`, `zizmor`, `periphery`.

## Getting started

```sh
git clone https://github.com/starhaven-io/Brewy.git
cd Brewy
just install-hooks   # enable the DCO sign-off commit hook (once per clone)
open Brewy.xcodeproj
```

## Local checks

The `justfile` wraps the common tasks — run them before opening a PR:

```sh
just lint        # SwiftLint (--strict)
just typos       # spell-check
just test        # unit tests (BrewyTests; UI tests need code signing)
just periphery   # unused-code scan
just audit       # GitHub Actions audit (zizmor)
just check       # everything above
```

CI builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `SWIFT_STRICT_CONCURRENCY=complete`, runs SwiftLint in `--strict` mode, and exercises the test suite under both Thread and Address sanitizers. Warnings and lint violations fail the build, so a clean `just check` locally is the best way to avoid CI surprises.

## Commits

- **Conventional Commits**: every commit message and PR title must be `type(scope): description`, where `type` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`. CI enforces this on both the PR title and each commit.
- **DCO sign-off**: every commit needs a `Signed-off-by:` trailer — use `git commit -s`. The `commit-msg` hook installed by `just install-hooks` rejects commits without it.
- If you used an AI assistant, include a `Co-Authored-By:` trailer.

## Pull requests

- Never push to `main`. Create a feature branch and open a PR.
- PRs are squash-merged with the PR number appended (e.g. `feat: add dependency tree (#123)`).
- Keep PR descriptions to a short summary of the change — no test-plan sections or tool-attribution footers.

## Architecture

See [CLAUDE.md](CLAUDE.md) for a map of the codebase, the `BrewService` architecture, the brew CLI commands used, and the gotchas / do-not-touch zones (notably: the app is intentionally unsandboxed, and all CLI calls must go through `CommandRunner` with an argument array).

## License

By contributing, you agree that your contributions are licensed under the project's [AGPL-3.0-only](LICENSE) license.
