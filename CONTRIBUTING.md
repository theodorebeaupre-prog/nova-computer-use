# Contributing to NOVA COMPUTER USE

Thanks for helping make native Computer Use safer and easier to audit.

## Before You Start

- Search existing issues before proposing a change.
- Keep changes focused; avoid unrelated refactors.
- Use macOS 15 or newer with a Swift 6 toolchain.
- For security-sensitive behavior, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Required Workflow

Bug fixes must begin with a focused regression test that fails for the reported behavior and passes after the fix. New behavior needs tests at the narrowest useful layer. Do not weaken bounds, permission checks, frontmost-app verification, cleanup, or input validation to make a test pass.

Before opening a pull request, run the full Swift suite:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

If the change affects packaging, plugin metadata, installation, signing, architectures, or release output, also run:

```bash
bash Tests/ScriptTests/UniversalBuildTests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-universal.sh
scripts/verify-release.sh dist/NovaComputerUsePlugin
```

Run `git diff --check` and review the final diff before submission.

## Sensitive Data Rules

Do not commit or attach:

- secrets, credentials, tokens, provisioning data, or private configuration;
- screenshots or screen recordings captured from a real workspace;
- Accessibility trees, typed text, or logs containing user content;
- absolute paths that expose another person's username or private directory names.

Use synthetic fixtures and disposable, non-sensitive test documents. Every pull request must explicitly confirm: **“I did not use sensitive data while testing this change.”**

## Pull Request Checklist

- [ ] A regression test failed before the bug fix, or new behavior has focused coverage.
- [ ] `swift test` succeeds with zero failures.
- [ ] Packaging verification succeeds when packaging-related files changed.
- [ ] The diff contains no secrets, captured screens, Accessibility content, or private paths.
- [ ] Documentation and error-code guidance match the implementation.
- [ ] I did not use sensitive data while testing this change.

Contributions are accepted under the repository's [AGPL-3.0-only license](LICENSE). Keep existing copyright, license, and derivation notices intact.
