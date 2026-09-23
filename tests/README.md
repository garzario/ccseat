# Tests

The ccseat test suite: plain bash, no test framework, and nothing to install beyond `bash`, `jq` and the usual tools (`shellcheck`, `zsh` and `fish` make a few more tests run instead of skipping).

```sh
make test                          # every test
bash tests/run.sh -j 8             # every test, 8 at a time
bash tests/run.sh -j 8 seats       # only tests whose "file:function" contains "seats"
bash tests/run.sh -v test_add      # one group, with the output of passing tests
bash tests/run.sh -l               # list the tests
```

`run.sh -h` lists every option. [docs/development.md](../docs/development.md#tests) covers how tests fit into lint and CI.

## What is here

| Path | What it holds |
|---|---|
| `run.sh` | the runner: finds every `test_*` function, runs each in its own sandbox, in parallel with `-j`, with a time limit |
| `lib.sh` | the sandbox, fixtures and assertions every test can use |
| `stubs/` | fake `claude`, `curl`, `security`, `trash` and `osascript` that keep their state in the sandbox |
| `fixtures/` | a sample status line input from Claude Code and a sample usage API answer |
| `test_cli.sh` | help, version, exit codes and `ccseat config` |
| `test_seats.sh` | first run, `add`, adopting folders, names, `use`, `rename`, `remove`, `sync` and the shared links |
| `test_launch.sh` | `run`, the picker and the `claude` wrapper, including auto-switch and seats that are out (LIMIT REACHED) |
| `test_usage.sh` | fetching, caching and showing usage, and keeping tokens out of every output |
| `test_statusline.sh` | drawing, installing and uninstalling the status line |
| `test_progress.sh` | `ccseat progress` |
| `test_shell.sh` | `ccseat init` in zsh, bash and fish, and the `cc` shortcut |
| `test_install.sh` | `install.sh`, `make install` and `ccseat uninstall` |
| `test_doctor.sh` | `ccseat doctor` |
| `test_hygiene.sh` | repository rules: shellcheck, bash 3.2 portability, no em dashes, no token on a command line, documentation links, and more |
| `test_security.sh` | regression tests for the security audit: tokens in traces and in curl's config, `~/.curlrc`, installer refs and checksums, uninstall and purge boundaries, escaping, control characters, private file modes |

## The sandbox

Every test function runs in a fresh subshell with:

- `HOME` set to an empty folder inside the sandbox, and every `XDG_*`, `CLAUDE_*` and `CCSEAT_*` variable unset,
- `PATH` starting with the stubs and the repository's `bin`, so `ccseat` is the code under test and `claude`, `curl` and (on macOS) `security`, `trash` and `osascript` are fakes,
- `TZ=UTC` and an English UTF-8 locale.

Nothing reaches your real `~/.claude`, your Keychain, your Trash or the network. On macOS, scripts run with `/bin/bash`, so bash 3.2 is what gets tested; `CCSEAT_TEST_BASH` picks another bash.

Sandboxes live in `.tmp/tests/` (ignored by git). Passing ones are removed; a failing test prints its sandbox path and keeps it, and `-k` keeps them all.

## The stubs

| Stub | What it does |
|---|---|
| `claude` | keeps a login per config folder like the real one; `auth login` signs in as `CCSEAT_STUB_LOGIN_EMAIL` (the account picked "in the browser"); anything else is logged to `$STUB/launches` as `<config folder><TAB><arguments>` |
| `curl` | answers the usage endpoint from `$STUB/usage/<token>.json`, and logs every command line to `$STUB/curl.args` so tests can check that no token appears there |
| `security` | a Keychain made of files in `$STUB/keychain/` |
| `trash` | moves paths into the sandbox's `~/.Trash` |
| `osascript` | always fails, so callers use their fallback |

`CCSEAT_STUB_LOGIN_FAIL=1` makes a login fail, and `CCSEAT_STUB_CURL_FAIL=1` makes the usage endpoint time out. For `file://` URLs the `curl` stub acts like a web server: a missing file answers 404, and a file `<path>.status` next to it holds another HTTP status to answer with.

A test that runs `ccseat uninstall` calls `program_copy` first (or, in `test_install.sh`, installs from `fake_clone`), so the program under test is never the one that goes to the Trash. `run.sh` fails the run if `bin/ccseat` or `lib/ccseat` has gone missing.

## Writing a test

Add a function whose name starts with `test_` to the file of its area. The runner finds it by name.

```sh
test_list_marks_the_current_seat() {
  make_primary alice@example.com       # a signed-in ~/.claude
  add_seat bob@example.com             # ccseat add, signing in as bob
  cs_ok use bob                        # runs ccseat; fails the test on a non-zero exit
  cs_ok list
  assert_contains "$OUT" "bob"
  assert_no_tokens                     # no token in stdout or stderr
}
```

- `run CMD...` runs any command and sets `OUT`, `ERR` and `RC`. `cs ARGS...` runs `ccseat`, and `cs_ok ARGS...` also fails the test when it does not exit 0.
- `run_pty KEYS... -- CMD...` runs a command in a pseudo terminal and types the keys, for the picker.
- Fixtures: `make_primary EMAIL`, `add_seat EMAIL [add options]`, `login_seat_dir DIR EMAIL`, `usage_fixture EMAIL P5 R5 P7 R7`, `write_credentials DIR EMAIL [expired]`.
- Assertions: `assert_eq`, `assert_contains`, `assert_match`, `assert_success`, `assert_exit`, `assert_file`, `assert_symlink`, `assert_json`, `assert_no_tokens` and more, all in `lib.sh`.
- `skip "reason"` skips a test that cannot run here (a missing `zsh`, say).

Use example people and addresses only: alice, bob, carol, work, personal, `@example.com`.
