# Troubleshooting

- [Start with ccseat doctor](#start-with-ccseat-doctor)
- [ccseat: command not found](#ccseat-command-not-found)
- [claude does not switch seats](#claude-does-not-switch-seats)
- [cc does not open the picker](#cc-does-not-open-the-picker)
- [Every seat uses the same account](#every-seat-uses-the-same-account)
- [The browser signed in with the wrong account](#the-browser-signed-in-with-the-wrong-account)
- [A seat's status looks wrong](#a-seats-status-looks-wrong)
- [A seat is missing a skill, setting or MCP server](#a-seat-is-missing-a-skill-setting-or-mcp-server)
- [The status line is missing or cut off](#the-status-line-is-missing-or-cut-off)
- [A seat's folder is missing](#a-seats-folder-is-missing)
- [Colors look wrong](#colors-look-wrong)
- [Still stuck?](#still-stuck)

## Start with ccseat doctor

```sh
ccseat doctor
```

It checks the tools ccseat needs, every seat's login and links, the shell integration, the status line and the usage API, and prints the fix under each problem. It changes nothing except refreshing the usage cache, and it exits with `1` when it finds a problem (warnings alone do not count).

```text
ccseat 0.2.0  ~/.local/share/ccseat/app/bin/ccseat

Tools
  ✓ bash 3.2.57(1)-release
  ✓ jq 1.8.1
  ✓ curl
  ✓ Claude Code 2.1.280 (~/.local/bin/claude)
  ✓ macOS Keychain (security)

Seats
  ✓ alice     alice@example.com, Max, primary, current
  ✓ work      work@example.com, Max
  ✓ personal  personal@example.com, Max

Shell
  ! the claude command does not switch seats yet (no shell integration)
      fix: ccseat setup
      or add to ~/.zshrc: eval "$(ccseat init zsh)"

Status line
  · not installed (optional)
      ccseat statusline install

Usage data
  ✓ the usage API answers for alice

0 problems, 1 warning.
```

## ccseat: command not found

The installer links the command into `~/.local/bin`. When that folder is not on your `PATH`, the shell block the installer adds puts it there, so:

- open a new terminal, or run `exec zsh` (or `exec bash`, `exec fish`),
- if you skipped the shell step, run `~/.local/bin/ccseat setup`, which adds the block and the `PATH` line,
- with Homebrew, the command is in Homebrew's own `bin` folder, which is already on your `PATH`.

## claude does not switch seats

Check what `claude` is in your shell:

```sh
type claude
```

It should say `claude` is a function. If it does not:

- **No shell integration yet.** Run `ccseat setup`, then open a new terminal.
- **Added, but this terminal started before.** Open a new terminal, or run `exec zsh` (or your shell).
- **An alias wins.** An `alias claude=...` line after ccseat's block makes `claude` skip ccseat. Delete that line; ccseat finds the real Claude Code by itself. `ccseat doctor` points to the file and line.

If `claude` is the function but it still opens the same seat:

- **Switching is off.** `ccseat config auto_switch` prints `on` or `off`; turn it on with `ccseat config auto_switch on`.
- **No other seat has room.** When every seat is at a limit, `claude` opens the one that resets first. `ccseat list` shows where each seat stands.
- **`CLAUDE_CONFIG_DIR` is exported** in your shell. A folder you set yourself wins over the current seat. Remove that `export` line, or open seats with `ccseat run` instead.
- **You ran `ccseat run` or picked a seat.** Those open exactly the seat you chose and never switch.

## cc does not open the picker

Check what `cc` is in your shell:

```sh
type cc
```

It should say `cc` is a function. If it does not:

- **No shell integration yet, or this terminal started before it.** Run `ccseat setup` if you have not, then open a new terminal.
- **You have your own `cc`.** A function or alias called `cc` that you made yourself wins, and ccseat leaves it alone. Remove it, or give the shortcut another name: `ccseat config shortcut cs`.
- **The shortcut is off or renamed.** `ccseat config shortcut` prints its name (`cc` by default, or `off`). After a change, open a new terminal.
- **You gave it arguments.** `cc` with arguments is the C compiler on purpose. Use `ccseat` with arguments instead: `ccseat list`, `ccseat run work`.

## Every seat uses the same account

`CLAUDE_CODE_OAUTH_TOKEN` in your environment makes Claude Code use that one token in every seat. Remove it to use each seat's own login. `ccseat doctor` warns about it. When `ANTHROPIC_API_KEY` is set, Claude Code may bill that key instead of the seat's plan, and `ccseat doctor` mentions that too.

## The browser signed in with the wrong account

The login happens in your browser, so a browser already signed in to claude.ai may pick that account. If it is an account you already added, ccseat signs that login out again and adds nothing. Sign out of claude.ai in the browser, or open the link Claude Code prints in a private window, and run `ccseat add` again.

## A seat's status looks wrong

`ccseat list` shows a status for each seat:

| Status | What to do |
|---|---|
| `limit reached until <time>` | nothing is wrong: the seat is at its 5-hour or weekly limit until that time, and `claude` uses another seat meanwhile. `limit_5h` and `limit_weekly` in [Configuration](configuration.md#settings) set when a seat counts as out |
| `not logged in` | open the seat once (`ccseat run <seat>`) and sign in, or add the account again |
| `idle` | nothing: the login expired while the seat was unused, and Claude Code renews it the next time the seat opens |
| `usage unavailable` | the usage API refused the login; open the seat once so Claude Code renews it |
| `offline` | the usage API could not be reached; check your connection or proxy. ccseat keeps using the last numbers |
| `no data yet` | wait a moment, or run `ccseat usage --refresh` |
| `12 min ago` | the numbers could not be refreshed recently; `ccseat usage --refresh` fetches them now |

If usage never shows for any seat, the usage endpoint may have changed; see the [FAQ](faq.md#what-if-anthropic-changes-the-usage-endpoint).

## A seat is missing a skill, setting or MCP server

```sh
ccseat sync
```

It repairs the shared links of every seat and copies the MCP servers and trusted folders from `~/.claude` again. This also happens silently every time a seat opens. If a seat still misses something, check the `share` setting (`ccseat config share`): an item that is not in the list is not shared. MCP servers you add with `claude mcp add --scope user` through the `claude` function reach every seat right away.

## The status line is missing or cut off

- **Missing:** run `ccseat statusline install`. If you had your own status line, ccseat keeps it aside and `ccseat statusline uninstall` puts it back. A seat that does not share `settings.json` needs `ccseat statusline install --seat <seat>`.
- **Cut off, or the next seat shows as a number:** Claude Code does not tell the status line how wide the terminal is, so it fits into 80 columns. On a wide terminal, raise that: `ccseat config statusline_width 120`. A `COLUMNS` variable in the environment Claude Code runs it in wins over that setting.
- **Preview it:** run `ccseat statusline` in a terminal.

## A seat's folder is missing

```text
ccseat: the folder of work is missing (~/.claude-work)
  Put the folder back, or remove the seat with: ccseat remove work
```

A seat remembers its folder by path. If you moved or deleted it, put it back, or remove the seat and add the folder again from its new place with `ccseat add --dir`.

## Colors look wrong

- `ccseat config colors never` turns colors off, and `always` forces them. `NO_COLOR` also turns them off.
- ccseat uses 24-bit colors. In Terminal.app it falls back to the nearest 256 colors, unless `COLORTERM` says the terminal supports 24-bit color.
- Main text uses your terminal's own foreground color, so light themes stay readable.

## Still stuck?

- Ask in [Discussions](https://github.com/garzario/ccseat/discussions).
- [Report a bug](https://github.com/garzario/ccseat/issues/new?template=bug_report.yml): only "What happened?" is required. The output of `ccseat doctor` and `ccseat version` helps; remove emails or folder names you do not want public first, and never paste a token or the contents of `.credentials.json`.
