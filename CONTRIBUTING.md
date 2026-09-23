# Contributing to ccseat

Thanks for helping. ccseat is a small bash tool, and we want it to stay easy to read, easy to install and safe to run on anyone's machine.

## Ground rules

- **Portable bash.** Everything must run on macOS `/bin/bash` 3.2 and on Linux bash 5. That means no associative arrays, no `mapfile`, no `${var,,}`, and a fallback for every GNU or BSD specific flag (`stat`, `date`, `sed -i`).
- **Never leak credentials.** Tokens are never printed, logged, cached or passed on a command line. The `Authorization` header goes to `curl` on stdin (`-K -`).
- **Never destroy user data.** No `rm -rf` on anything the user owns. Removing a seat moves its folder to the Trash.
- **Keep the user's Claude Code setup intact.** Shared files are symlinks into the primary config folder. Per-seat files (credentials, `.claude.json`) are never shared.
- **English everywhere**: code, comments, messages and docs. No abbreviations in user-facing text (`5-hour`, not `5h`).

## Development setup

```sh
git clone https://github.com/garzario/ccseat
cd ccseat
./install.sh --yes     # links your clone, so edits take effect right away
```

You need `bash`, `jq`, `curl`, `shellcheck`, and optionally `zsh` and `fish` to check the shell integrations.

## Tests and lint

```sh
make test    # runs tests/run.sh in a sandbox HOME with stubbed claude, security and curl
make lint    # shellcheck on every script
```

The test suite never touches your real `~/.claude`, your Keychain or the network. If you add a command or change behavior, add or update a test in `tests/test_*.sh`. CI runs both targets on macOS and Ubuntu for every push and pull request.

## Pull requests

1. Open an issue first for anything bigger than a bug fix, so we can agree on the approach.
2. Keep each pull request focused on one change.
3. Make sure `make test` and `make lint` pass.
4. Describe what changed and how you tested it, and add an entry under "Unreleased" in `CHANGELOG.md`.

## Reporting bugs

Use the bug report template and include the output of `ccseat doctor` and `ccseat version`. Remove anything private (emails, paths) first. Never paste tokens or the contents of `.credentials.json`.

## Security issues

Please do not open a public issue. See [SECURITY.md](SECURITY.md).
