# Contributing to ccseat

**[Report a bug](https://github.com/garzario/ccseat/issues/new?template=bug_report.yml)** · **[Request a feature](https://github.com/garzario/ccseat/issues/new?template=feature_request.yml)** · **[Ask a question](https://github.com/garzario/ccseat/discussions)**

Thanks for helping. ccseat is a small bash tool, and we want it to stay easy to read, easy to install and safe to run on anyone's machine. Every kind of help counts: a question that shows where the docs are unclear, a bug report, an idea, a fix.

- [Ask a question or share an idea](#ask-a-question-or-share-an-idea)
- [Report a bug](#report-a-bug)
- [Propose a feature](#propose-a-feature)
- [Report a security problem](#report-a-security-problem)
- [Your first contribution](#your-first-contribution)
- [Pull requests](#pull-requests)
- [Coding rules](#coding-rules)
- [What to expect](#what-to-expect)

## Ask a question or share an idea

Use [GitHub Discussions](https://github.com/garzario/ccseat/discussions): questions, ideas that are not fully formed yet, and setups you want to show. Check the [FAQ](../docs/faq.md) and [Troubleshooting](../docs/troubleshooting.md) first; your answer may be there. Please do not open an issue for a question.

## Report a bug

Open a [bug report](https://github.com/garzario/ccseat/issues/new?template=bug_report.yml). Only one box is required: what happened, in your own words. The rest is optional and helps a fix come sooner:

- the steps to reproduce it,
- your operating system and shell,
- the output of `ccseat version` and `ccseat doctor`.

Remove anything private first, such as emails or folder names you do not want public. **Never paste a token or the contents of `.credentials.json`.** Search the [open issues](https://github.com/garzario/ccseat/issues) before you file, and add to an existing one when it is the same problem.

## Propose a feature

Open a [feature request](https://github.com/garzario/ccseat/issues/new?template=feature_request.yml). Only "What would you like?" is required; "Why would it help?" is optional, but the problem behind an idea (what is hard or slow today when you use several Claude Code accounts) often matters more than the idea itself. For something big, wait until the maintainer agrees on the approach before you write code, so no work is wasted.

## Report a security problem

Do not open a public issue. Report it privately as the [security policy](SECURITY.md) describes.

## Your first contribution

Issues labeled [`good first issue`](https://github.com/garzario/ccseat/labels/good%20first%20issue) are small and well described, and [`help wanted`](https://github.com/garzario/ccseat/labels/help%20wanted) marks work the maintainer would welcome help with. Comment on the issue to say you are taking it, so two people do not do the same work.

To get set up:

```sh
git clone https://github.com/garzario/ccseat
cd ccseat
./install.sh --yes     # links your clone, so edits take effect right away
make check             # lint and the whole test suite
```

You need `bash`, `jq`, `curl` and `shellcheck`, and optionally `zsh` and `fish` to test the shell integrations. [docs/development.md](../docs/development.md) explains the layout, the tests and how to add a command, and [tests/README.md](../tests/README.md) how to write a test.

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep each pull request to one change. Open an issue first for anything bigger than a bug fix.
3. Add or update tests in `tests/test_*.sh` for every change in behavior.
4. Update the documentation in `docs/` when something users see changes, and add a line under "Unreleased" in [CHANGELOG.md](../CHANGELOG.md).
5. Run `make check`. CI runs the same lint and tests on macOS (bash 3.2) and Ubuntu, plus the Homebrew formula, and it must pass.
6. Open the pull request against `main` and fill in the template. The maintainer ([@garzario](https://github.com/garzario), the code owner) reviews every pull request.

Checklist before you ask for a review:

- [ ] `make test` passes
- [ ] `make lint` passes
- [ ] tested on macOS or Linux, in zsh, bash or fish, as the change needs
- [ ] tests cover the change
- [ ] docs and `CHANGELOG.md` are updated

## Coding rules

- **Portable bash.** Everything must run on macOS `/bin/bash` 3.2 and on Linux bash 5. That means no associative arrays, no `mapfile`, no `${var,,}`, and a fallback for every GNU or BSD specific flag (`stat`, `date`, `sed -i`). The test suite checks for the common mistakes.
- **Never leak credentials.** Tokens are never printed, logged, cached, written to a file or passed on a command line. The `Authorization` header goes to `curl` on standard input (`-K -`).
- **Never destroy user data.** No `rm -rf` on anything the user owns. Removing a seat moves its folder to the Trash, and a file ccseat replaces is backed up first.
- **Keep the user's Claude Code setup intact.** Shared files are symlinks into `~/.claude`. Per-seat files (the login, `.claude.json`) are never shared.
- **Call tools by name,** never by absolute path, so `PATH` (and the test stubs) decide which `claude`, `curl` or `security` runs.
- **English everywhere:** code, comments, messages and docs.
- **No abbreviations in user-facing text:** `5-hour`, not `5h`; `weekly`, not `wk`; `context`, not `ctx`.
- **Plain words** in messages: say what happened and give the exact command that fixes it.
- **Example data only:** people and seats in tests and docs are alice, bob, carol, work and personal, with `@example.com` addresses.

## What to expect

ccseat is maintained on a best-effort basis by one person. The maintainer triages new issues and pull requests once a week: new issues get the `needs triage` label until then, and every pull request gets a review. Please be patient, and feel free to ask for an update when something has been quiet for two weeks.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
