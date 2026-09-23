# Development

Everything a contributor or maintainer needs: the layout, the tests, the lint, CI, adding a command and releasing. Read the [contributing guide](../.github/CONTRIBUTING.md) for the rules every change follows.

- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [How the program runs](#how-the-program-runs)
- [Tests](#tests)
- [Lint](#lint)
- [Continuous integration](#continuous-integration)
- [Adding a command](#adding-a-command)
- [Releasing](#releasing)

## Repository layout

```text
ccseat/
├── bin/ccseat            the entry point: loads lib/ccseat, help text, dispatch
├── lib/ccseat/           the program, one file per area (see the code map)
├── install.sh            the one-line installer (also works from a clone)
├── Makefile              make install, uninstall, test, lint, check
├── Formula/ccseat.rb     the Homebrew formula; this repository is also a tap
├── tests/                the test suite (see tests/README.md)
│   ├── run.sh            the runner: sandboxes, parallel jobs, time limits
│   ├── lib.sh            sandbox setup, fixtures and assertions
│   ├── stubs/            fake claude, curl, security, trash and osascript
│   ├── fixtures/         sample status line input and usage API answer
│   └── test_*.sh         the tests, one file per area
├── docs/                 the documentation, with images in docs/assets/
├── .github/              CI, issue forms, and the community files
├── CHANGELOG.md
└── LICENSE
```

The [code map](how-it-works.md#code-map) says what each file in `lib/ccseat/` does.

## Getting started

```sh
git clone https://github.com/garzario/ccseat
cd ccseat
./install.sh --yes     # links your clone, so edits take effect right away
```

You need `bash`, `jq`, `curl` and `shellcheck`, and optionally `zsh` and `fish` to test the shell integrations. On macOS: `brew install jq shellcheck fish`.

To try a change without touching your real setup, run it against a throwaway home folder:

```sh
HOME=$(mktemp -d) ./bin/ccseat help
```

## How the program runs

`bin/ccseat` finds its own real path (following symlinks, since macOS has no `readlink -f`), then sources the library in this order: `core`, `auth`, `usage`, `seats`, `picker`, `shell`, `doctor`. Any other `lib/ccseat/*.sh` file (today `statusline.sh` and `progress.sh`) is optional and loaded when present. Then it sets up the locale, paths, settings and colors, and calls `ccseat_main`, which dispatches to a `ccseat_cmd_<name>` function.

Everything runs on the `/bin/bash` 3.2 that macOS ships and on bash 5, with `jq` for all JSON.

## Tests

```sh
make test                          # every test
bash tests/run.sh -j 8             # every test, 8 at a time
bash tests/run.sh -j 8 picker      # only tests whose "file:function" contains "picker"
bash tests/run.sh -l               # list the tests
```

Each test runs in its own sandbox: a fresh `HOME`, a `PATH` that starts with stubs for `claude` and `curl` (plus `security`, `trash` and `osascript` on macOS), and the repository's `bin`. The suite never touches your real `~/.claude`, your Keychain, your Trash or the network. On macOS it runs the scripts with `/bin/bash`, so bash 3.2 is what gets tested.

| Option | What it does |
|---|---|
| `-j N` | run N tests at a time (default 1) |
| `-v` | print the output of passing tests too |
| `-k` | keep every sandbox (failed ones are always kept) |
| `-t SECONDS` | time limit per test (default 60) |
| `-l` | list the tests and exit |

Sandboxes go to `.tmp/tests/` in the repository (ignored by git). A failed test prints its sandbox path, so you can look at the files it left.

[tests/README.md](../tests/README.md) explains how to write a test.

## Lint

```sh
make lint     # shellcheck on every script, stub and test
make check    # lint, then test
```

CI uses shellcheck 0.11.0, so use that version or newer to get the same results. `.shellcheckrc` treats every file as bash and follows `source` lines. `tests/test_hygiene.sh` adds the rules shellcheck cannot check: no bash 4 features, no em dashes, no recursive `rm` in the program, no token on a command line, working links in the documentation, and more.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push and pull request:

| Job | What it does |
|---|---|
| shellcheck | `make lint` on Ubuntu |
| tests (ubuntu-latest) | the whole suite with bash 5, zsh and fish |
| tests (macos-latest) | the whole suite with the system `/bin/bash` 3.2 |
| homebrew formula | taps this repository, installs the formula, runs `brew test` and `brew style` |

Dependabot opens one pull request a week when a GitHub Action used by CI has a new version.

## Adding a command

Say the new command is `ccseat hello`.

1. **Write it.** Add `ccseat_cmd_hello` to the library file of its area in `lib/ccseat/`, or to a new `lib/ccseat/hello.sh`, which is loaded automatically. Parse its options in a `while` loop like the other commands, answer `-h` and `--help` with `ccseat_help hello`, and report wrong usage with `ccseat_die_usage` (exit code 2).
2. **Dispatch it.** In `ccseat_main` in `bin/ccseat`, add `hello` to the list of known commands and call `ccseat_cmd_hello "$@"`.
3. **Document it in the program.** Add a `hello)` entry to `ccseat_help` and a line to the command list in `ccseat__help_main`, both in `bin/ccseat`.
4. **Complete it.** Add `hello:<what it does>` to `CCSEAT_COMMANDS` in `lib/ccseat/shell.sh`, so zsh, bash and fish complete it.
5. **Test it.** Add `test_*` functions to the right `tests/test_*.sh` file, and add `hello` to the lists in `test_help_lists_every_command` and `test_every_command_has_help` in `tests/test_cli.sh`.
6. **Document it here.** Add it to [docs/commands.md](commands.md), to [docs/usage.md](usage.md) when it changes how people work, and add a line under "Unreleased" in [CHANGELOG.md](../CHANGELOG.md).

Then run `make check`.

## Releasing

Releases follow [Semantic Versioning](https://semver.org/). The version lives in three places that must agree, and `test_version_matches_changelog_and_formula` checks them: `CCSEAT_VERSION` in `lib/ccseat/core.sh`, a `## [X.Y.Z]` heading in `CHANGELOG.md`, and the tarball URL in `Formula/ccseat.rb`.

1. **Prepare the release commit** on an up-to-date `main` with green CI:
   - set `CCSEAT_VERSION="X.Y.Z"` in `lib/ccseat/core.sh`,
   - in `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a new empty `## [Unreleased]` above it, and update the compare links at the bottom,
   - in `Formula/ccseat.rb`, point `url` at `.../archive/refs/tags/vX.Y.Z.tar.gz` (the checksum comes in step 5),
   - run `make check`, then commit as `ccseat X.Y.Z`.
2. **Tag and push:**

   ```sh
   git tag -a vX.Y.Z -m "ccseat X.Y.Z"
   git push origin main vX.Y.Z
   ```

   The maintainer pushes release commits straight to `main`. The ruleset on `main` lets admins bypass it, so git prints "Bypassed rule violations"; everyone else goes through a pull request.
3. **Publish the release notes** from the changelog:

   ```sh
   v=X.Y.Z
   notes=$(mktemp)
   awk -v v="$v" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^(## )?\[/ {exit} on {print}' CHANGELOG.md > "$notes"
   gh release create "v$v" --title "ccseat $v" --notes-file "$notes"
   ```

4. **Publish the checksum.** The one-line installer checks the release against a `SHA256SUMS` file attached to it, with a line for `ccseat-X.Y.Z.tar.gz`, GitHub's archive of the tag:

   ```sh
   cd "$(mktemp -d)"
   curl -fsSL -o "ccseat-$v.tar.gz" "https://github.com/garzario/ccseat/archive/refs/tags/v$v.tar.gz"
   shasum -a 256 "ccseat-$v.tar.gz" > SHA256SUMS
   gh release upload "v$v" SHA256SUMS --repo garzario/ccseat
   cat SHA256SUMS
   ```

5. **Update the formula's checksum.** The tarball of a tag cannot contain its own checksum, so it goes in a commit after the tag. Put the checksum from `SHA256SUMS` in the `sha256` line of `Formula/ccseat.rb`, and commit as `Formula: checksum of the vX.Y.Z release`. Until this commit is pushed, the homebrew formula job in CI fails, because the formula still has the previous release's checksum.
6. **Check the release:** the plain one-line installer should print "Checked the download against the checksum published with vX.Y.Z", `brew upgrade ccseat` (or `brew install ccseat` on a clean tap) should install the new version, and `ccseat version` should print it.
