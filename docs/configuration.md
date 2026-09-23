# Configuration

ccseat works without any configuration. This page lists what you can change, and where ccseat keeps its files.

- [Settings](#settings)
- [What every seat shares](#what-every-seat-shares)
- [Environment variables](#environment-variables)
- [Files and folders](#files-and-folders)

## Settings

`ccseat config` prints every setting, `ccseat config <setting>` prints one, and `ccseat config <setting> <value>` changes one. The value `default` puts the default back.

```sh
ccseat config                  # every setting
ccseat config limit_5h 90      # count 90% of the 5-hour window as the limit
ccseat config limit_5h default
```

| Setting | Default | What it does |
|---|---|---|
| `auto_switch` | `on` | `claude` opens the freest seat when the current one is at its limit (`on` or `off`) |
| `limit_5h` | `95` | 5-hour usage, in percent from 1 to 100, that counts as the limit |
| `limit_weekly` | `100` | weekly usage, in percent from 1 to 100, that counts as the limit |
| `remember` | `on` | the seat you open from the picker becomes the current seat (`on` or `off`) |
| `shortcut` | `cc` | the short command the shell integration defines for the picker: a name of letters, digits, dashes and underscores (at most 32, not a shell keyword or builtin), or `off` for none; see [The shortcut](#the-shortcut) |
| `share` | 14 items | what every seat shares with `~/.claude`, separated by commas; see below |
| `colors` | `auto` | `auto`, `always` or `never`; `auto` uses colors on a terminal unless `NO_COLOR` is set |
| `statusline_width` | `80` | columns the status line fits into, from 40 to 400; Claude Code does not tell the status line how wide the terminal is, so raise it on a wide terminal to see the full name of the seat to switch to |

Settings are stored as `setting=value` lines in `~/.config/ccseat/config`. A line with a typo is ignored, so a hand edit never breaks the `claude` command.

### The shortcut

The shell integration defines a short command for the picker, in interactive shells only. It is `cc` by default:

- the shortcut with no arguments opens the picker, like `ccseat`,
- with arguments, `cc` runs your real `cc`, so `cc -o hello hello.c` still compiles (on a system without a C compiler, `cc list` runs `ccseat list`); any other name always runs `ccseat` with the arguments, so `cs list` is `ccseat list`,
- a function or alias of that name that you made yourself always wins: ccseat leaves it alone and defines no shortcut.

```sh
ccseat config shortcut cs        # use cs instead of cc
ccseat config shortcut off       # no shortcut at all
ccseat config shortcut default   # back to cc
```

The shell reads the setting when it starts, so open a new terminal (or run `exec zsh`, `exec bash` or `exec fish`) after a change. The `claude` function does not depend on this setting.

## What every seat shares

The `share` setting lists the items of `~/.claude` that every seat links to. The default is:

`settings.json`, `CLAUDE.md`, `skills`, `agents`, `commands`, `rules`, `hooks`, `output-styles`, `plugins`, `projects`, `file-history`, `plans`, `todos`, `history.jsonl`

Status line scripts that your `settings.json` runs from inside `~/.claude` are shared too, so a custom status line works in every seat.

To share less, set a shorter list. ccseat removes the links it made for the rest, and `default` brings them back:

```sh
ccseat config share settings.json,CLAUDE.md,skills
ccseat config share default
```

Some items can never be shared, whatever the list says, because they belong to one account: the login (`.credentials.json`), `.claude.json`, sessions, caches, telemetry, IDE state and a few others. ccseat refuses them with a message. [How it works](how-it-works.md#what-is-shared) has the full picture, and the [FAQ](faq.md#can-i-keep-a-seat-isolated) shows how to keep one seat apart.

## Environment variables

| Variable | Effect |
|---|---|
| `CCSEAT_NO_WRAP=1` | the `claude` shell function runs Claude Code directly, without ccseat |
| `CCSEAT_HOME` | where ccseat keeps its settings and seat list (default `~/.config/ccseat`) |
| `CCSEAT_YES=1` | answer yes to ccseat's questions, and to the installer's |
| `CCSEAT_CLAUDE` | the path of the `claude` program to run, when it is not the one on your `PATH` |
| `CCSEAT_REF` | what the installer installs, the same as its `--ref` option. The installer installs the latest release by default (`latest`); `main` (like `--ref main`) is the development version, and `vX.Y.Z` (like `--ref v0.2.0`) is that tagged release. See [Installation](installation.md#one-line-installer) |
| `NO_COLOR` | no colors, unless `colors` is `always` |
| `COLUMNS` | when set, the status line fits into this width instead of `statusline_width` |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` | respected for settings, seat folders and cache |

ccseat sets two variables of its own:

| Variable | Set where | Value |
|---|---|---|
| `CCSEAT_SEAT` | in every Claude Code session ccseat opens | the seat's name, for your hooks and scripts |
| `CCSEAT_SHELL` | in interactive shells with the shell integration | `zsh`, `bash` or `fish` |

## Files and folders

ccseat's own folders, and the seat folders it creates, are private to your user (mode `700`).

| Path | What it holds |
|---|---|
| `~/.config/ccseat/seats` | the seat list: one `name<TAB>folder` line per seat |
| `~/.config/ccseat/current` | the name of the current seat |
| `~/.config/ccseat/config` | your settings |
| `~/.config/ccseat/backups/` | copies made before a change: `settings.json` before each status line change (the newest three), and shell startup files before the installer edited them |
| `~/.config/ccseat/statusline-previous.json` | the status line you had before `ccseat statusline install`, which `uninstall` puts back |
| `~/.local/share/ccseat/seats/` | the folders of the seats `ccseat add` created |
| `~/.local/share/ccseat/app/` | the program, when the one-line installer downloaded it |
| `~/.cache/ccseat/` | the last usage answer of each seat (usage windows and reset times only, never tokens) |
| `<seat folder>/.ccseat.json` | which links and MCP servers ccseat added to that seat |
| `<seat folder>/.ccseat-backup/` | the seat's own copies of shared files, kept when a folder was adopted |

Your `~/.claude` folder is the primary seat. ccseat opens it exactly like plain `claude` does, and creates missing shared items in it so that every link is valid. It edits `~/.claude/settings.json` only for `ccseat statusline install` and `uninstall`.
