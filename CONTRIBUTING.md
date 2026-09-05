# Contributing

Thanks for helping improve Brewy. This document covers the local setup, verification commands, and conventions expected before opening a pull request.

## Requirements

- macOS 15.0 or later (Apple Silicon)
- Xcode 26 or later
- [Homebrew](https://brew.sh). Brewy shells out to the local `brew` installation.
- [`just`](https://github.com/casey/just) for the local task runner (`brew install just`)

Optional tooling used by the full local gate:

```sh
brew install swiftlint typos-cli zizmor lychee
```

## Getting started

```sh
git clone https://github.com/starhaven-io/Brewy.git
cd Brewy
just install-hooks   # enable git hooks: pre-push check + DCO sign-off (once per clone)
open Brewy.xcodeproj
```

Brewy is a native SwiftUI macOS app. The project uses MVVM-style views and models, Swift Testing for unit tests, Sparkle for app updates, and direct Homebrew CLI execution through `CommandRunner`.

## Local checks

The `justfile` wraps the common tasks. Run the focused command while iterating, then run `just check` before pushing:

```sh
just build       # debug build without local code signing
just lint        # SwiftLint (--strict)
just typos       # spell-check
just test        # unit tests (BrewyTests; UI tests need code signing)
just test-ui     # UI tests with an ad hoc-signed test runner
just audit       # GitHub Actions audit (zizmor)
just lychee      # README and CONTRIBUTING link check
just check       # full static and unit-test gate
```

Once you've run `just install-hooks`, the pre-push hook runs `just check` automatically on `git push`.

CI builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, runs SwiftLint in `--strict` mode, audits workflows when they change, exercises unit tests under sanitizer configurations, and runs UI tests with an ad hoc-signed runner. Warnings and lint violations fail the build, so a clean `just check` locally is the best way to avoid CI surprises.

Run `just lychee` after changing links in README or CONTRIBUTING.

## Documentation and assets

- Keep README copy aligned with the current app UI, installation flow, and security model.
- Do not keep stale screenshots or demo recordings in the README.
- Edit `Brewy/AppIcon.icon` in Icon Composer, then export and update `assets/BrewyIcon.png` when the app icon changes.
- Update `assets/BrewyScreenshot.png` when the main app UI changes materially.
- Prefer concise docs that describe what the app does and how to verify changes.
- Keep PR descriptions short; the repository does not use generated test-plan or tool-attribution sections.

## Commits

- **Conventional Commits**: every commit message and PR title must be `type(scope): description`, where `type` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`. CI enforces this on both the PR title and each commit.
- **DCO sign-off**: every commit needs a `Signed-off-by:` trailer — use `git commit -s`. The `commit-msg` hook installed by `just install-hooks` rejects commits without it.
- Do not identify an AI tool or model as an author, co-author, committer, or signatory. AI attribution does not belong in commit trailers.

## Pull requests

- Never push to `main`. Create a feature branch and open a PR.
- PRs are squash-merged with the PR number appended (e.g. `feat: add dependency tree (#123)`).
- Keep PR descriptions to a short summary of the change.
- If AI assisted with a PR, end the initial PR description with exactly one unformatted line: `AI disclosure: <model> with <how the output was verified>.`

## Architecture guardrails

- Brewy is intentionally not sandboxed because it must execute the user's Homebrew installation and manage local packages.
- All command execution must go through `CommandRunner` or `CommandRunning` with argument arrays.
- External package, tap, appcast, and release-note metadata is untrusted. Open external URLs only through `ExternalURLPolicy`.
- Destructive actions need previews or confirmations. Cleanup and autoremove use Homebrew dry-run output before execution.
- Mac App Store apps are read through `mas`; do not route MAS upgrades through `brew upgrade`.
- Preserve cache schema versioning and derived-state invalidation when changing package data.

See [AGENTS.md](AGENTS.md) for the full codebase map, `BrewService` architecture notes, release workflow constraints, and do-not-touch rules.

## License

By contributing, you agree that your contributions are licensed under the project's [AGPL-3.0-only](LICENSE) license.
