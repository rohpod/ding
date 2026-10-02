# Contributing to ding

Thanks for your interest in contributing to ding! This is a small, open-source project, and contributions of any kind — bug fixes, features, docs, tests — are welcome.

## Before you start

- For setup instructions (building, running, testing), see the [README](README.md).
- There's no formal process for proposing work. Open an issue or just send a PR, whichever you prefer. Any PR is welcome.
- All changes go through review before merging.

## Code style

- ding targets Swift 6 with strict concurrency enabled. New code should be actor-isolation-correct — no unsafe opt-outs (`@unchecked Sendable`, `nonisolated(unsafe)`, etc.) without a clear justification in a comment.
- Match the existing architecture where possible: actor-per-account background workers, `@MainActor` UI/coordination layer, protocol-backed seams for testability (e.g. `KeychainServiceProtocol`, `IMAPConnecting`) with fakes for tests rather than live network/Keychain calls.
- Keep naming conventions consistent with the existing codebase (e.g. lowercase `ding` for the app/bundle/folder names, `Sources/ding`, `Tests/dingTests`).

## Tests

- Add or update tests for behavioural changes where practical. The project currently has test coverage via `swift test`, with fakes for IMAP and Keychain so tests stay hermetic.
- CI runs `swift build` and `swift test` on PRs. Please make sure both pass locally first.

## Commits

- Keep PRs focused. Ideally, one logical change per PR.
- Commit messages: short, plain-language summaries (not technical changelogs).

## Questions

Open an issue or reach out via GitHub ([@rohpod](https://github.com/rohpod)) — anywhere works.

## License

By contributing, you agree that your contributions will be licensed under the same license as this project (see [LICENSE](LICENSE)).
