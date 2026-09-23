# Commands

Every ccseat command, with its options. `ccseat help <command>` prints a command's help in your terminal.

Wherever a command takes a `<seat>`, you can type the seat's name, the start of its name (when only one seat matches), its number in `ccseat list`, its email, or its folder.

| Command | What it does |
|---|---|
| [`claude`](#claude) | Claude Code in the current seat, switching at a limit |
| [`cc`, `ccseat`](#ccseat-pick) | Pick a seat with the arrow keys and open it |
| [`ccseat run`](#ccseat-run) | Open Claude Code with a seat |
| [`ccseat list`](#ccseat-list) | Every seat with its usage, reset times and status |
| [`ccseat usage`](#ccseat-usage) | Usage bars for a seat |
| [`ccseat add`](#ccseat-add) | Sign in to another account and add it as a seat |
| [`ccseat use`](#ccseat-use) | Make a seat the current one |
| [`ccseat current`](#ccseat-current) | Print the current seat |
| [`ccseat rename`](#ccseat-rename) | Rename a seat |
| [`ccseat remove`](#ccseat-remove) | Remove a seat |
| [`ccseat sync`](#ccseat-sync) | Repair shared links and copy MCP servers and trusted folders |
| [`ccseat setup`](#ccseat-setup) | Add the shell integration to your startup file |
| [`ccseat init`](#ccseat-init) | Print the shell integration |
| [`ccseat statusline`](#ccseat-statusline) | The Claude Code status line |
| [`ccseat progress`](#ccseat-progress) | Workflows and agents running in a session |
| [`ccseat doctor`](#ccseat-doctor) | Check everything and print fixes |
| [`ccseat config`](#ccseat-config) | Read or change settings |
| [`ccseat uninstall`](#ccseat-uninstall) | Remove ccseat |
| [`ccseat help`](#ccseat-help) | Help for ccseat or one command |
| [`ccseat version`](#ccseat-version) | Print the version |

`ls`, `rm`, `mv` and `switch` also work for `list`, `remove`, `rename` and `use`. Once the shell integration is on, `cc` with no arguments opens the picker, and `cc` with arguments is still the C compiler (see [`ccseat init`](#ccseat-init)).

**Exit codes:** `0` done, `1` error, `2` wrong usage (an unknown command or option), `130` cancelled.

## Everyday

### claude

```text
claude [claude arguments]
```

With the [shell integration](installation.md#the-shell-integration), `claude` runs `ccseat claude`, which opens Claude Code with the current seat. When `auto_switch` is on and that seat is at its limit, it opens the freest seat instead and says so in one line. Every argument goes to Claude Code as it is. See [Auto-switch](usage.md#auto-switch) for the details.

To skip ccseat for one command, run `command claude` or set `CCSEAT_NO_WRAP=1`.

### ccseat (pick)

```text
ccseat [pick]
cc
```

Shows every seat with its 5-hour and weekly usage and opens Claude Code with the one you choose. `cc`, the [shortcut](#ccseat-init), does the same. The cursor starts on the freest seat, and the chosen seat becomes the current one (`ccseat config remember off` turns that off). With no seats yet, it offers to add one. When the output is not a terminal, it prints `ccseat list` instead.

A seat that is out shows `LIMIT REACHED` in bold red after its name, then `back <time>`, the time it comes back (the later reset when both windows are out). The bar and percent of the window at its limit are red, and the seat's other rows are dimmed. Opening an out seat asks first, inside the picker: `personal is out until Thursday 4:00 PM. Open it anyway? (y/N)`. Only `y` opens it; any other key goes back to the list.

| Key | Action |
|---|---|
| `↑` `↓` or `k` `j` | move |
| `Home` `End` or `g` `G` | first or last seat |
| `Enter` | open the selected seat |
| `1` to `9` | open that seat right away |
| `q`, `Esc` or `Ctrl-C` | cancel |

### ccseat run

```text
ccseat run <seat> [claude arguments]
ccseat <seat> [claude arguments]
```

Opens Claude Code with a seat, once, without changing the current seat and without switching at a limit. Any other arguments go to `claude` as they are. If the seat has no login yet, it signs you in first. `ccseat <seat>` is short for `ccseat run <seat>` when you type the seat's full name.

```sh
ccseat run work
ccseat run 2 --resume
ccseat run work -p "summarize the README"
```

When the seat is out, it prints one warning line on stderr and opens it anyway:

```text
ccseat: personal is out until Thursday 4:00 PM (weekly limit), opening it anyway.
```

### ccseat list

```text
ccseat list [--json]
```

Every seat with its number, 5-hour and weekly usage, when each resets, and a status. The current seat is marked with `❯`. A seat that is out says `limit reached until <time>` in bold red (just `limit reached` when the table has no room for the time, which the resets column still shows). In a narrow terminal each seat takes a few lines instead of one row. The statuses are explained in [Usage at a glance](usage.md#usage-at-a-glance).

| Option | What it does |
|---|---|
| `--json` | the same as JSON, for scripts: name, email, folder, plan, percents, reset times, status |

### ccseat usage

```text
ccseat usage [seat] [--refresh] [--all] [--json]
```

The 5-hour and weekly usage of a seat, the current one by default, as bars with the time each window resets. It also shows any weekly limit of a single model (for example "Opus weekly") from a usage answer of the past 6 hours. Numbers under a minute old come from the cache. Switching seats at a limit looks at the 5-hour and weekly limits only.

| Option | What it does |
|---|---|
| `-r`, `--refresh` | fetch now; without a seat, fetch every seat |
| `-a`, `--all` | show every seat |
| `--json` | print JSON; for one seat it includes the last raw answer of the usage API |

## Seats

### ccseat add

```text
ccseat add [email] [--email EMAIL] [--name NAME] [--dir FOLDER]
```

Signs in to another Claude account and adds it as a seat. Your browser opens for the login: sign in with the account you want to add. The seat is named after the part of its email before the `@`, so `bob@example.com` becomes `bob`, and a second `bob` becomes `bob-2`.

With no seats yet and `~/.claude` not signed in, the first account signs in to `~/.claude` itself, so plain `claude` and editors use it too. An account that is already a seat is never added twice.

| Option | What it does |
|---|---|
| `--email EMAIL` | fill in this email on the login page (or give the email on its own: `ccseat add bob@example.com`) |
| `--name NAME` | choose the seat's name yourself |
| `--dir FOLDER` | use an existing Claude Code config folder instead of a new one, for example one you opened with `CLAUDE_CONFIG_DIR`; when it is already signed in, no login is needed. Use it only on folders you made yourself: a config folder can run commands (hooks, MCP servers), and its skills and agents are copied into `~/.claude`. A git repository or a project's `.claude` folder is refused |

```sh
ccseat add
ccseat add bob@example.com
ccseat add --name client
ccseat add --dir ~/.claude-work
```

> [!WARNING]
> `ccseat add --dir` is only for folders you made yourself. A config folder can run commands through its hooks and MCP servers, and its skills and agents are copied into `~/.claude`, where every seat uses them. Never adopt a folder someone else gave you or one that came with a download. [Adopting an existing folder](how-it-works.md#adopting-an-existing-folder) explains what happens to its files.

### ccseat use

```text
ccseat use <seat>
```

Makes a seat the current one without opening it. The `claude` command and the status line use the current seat.

### ccseat current

```text
ccseat current [--dir]
```

Prints the name of the current seat, or with `--dir` its config folder.

### ccseat rename

```text
ccseat rename <seat> <new name>
```

Renames a seat. Names use lowercase letters, digits, dots, dashes and underscores, start with a letter or a digit, and cannot be only digits. The folder stays where it is, so the login keeps working.

### ccseat remove

```text
ccseat remove <seat> [--keep-files] [-y]
```

Removes a seat: signs it out and moves its folder to the Trash. Nothing is deleted. The primary seat (`~/.claude`) is never removed. It asks first.

| Option | What it does |
|---|---|
| `-k`, `--keep-files` | keep the folder and its login where they are; `ccseat add --dir` brings the seat back |
| `-y`, `--yes` | do not ask for confirmation |

### ccseat sync

```text
ccseat sync [seat]
```

Brings every seat, or one, up to date with `~/.claude`: repairs the shared links, copies the MCP servers and marks the same folders as trusted. This also runs silently every time a seat opens. MCP servers a seat added on its own are kept.

```text
$ ccseat sync
work: 2 MCP servers, 1 trusted folder, 14 items shared
personal: 2 MCP servers, 1 trusted folder, 14 items shared
```

## Setup

### ccseat setup

```text
ccseat setup [zsh|bash|fish] [--statusline | --no-statusline] [-y]
```

Adds the shell integration to your shell startup file (once), makes your current Claude Code login the first seat, and offers the status line. The shell comes from `$SHELL` unless you name one.

| Option | What it does |
|---|---|
| `--shell NAME` | set up `zsh`, `bash` or `fish` (the same as naming it) |
| `--statusline` | install the status line without asking |
| `--no-statusline` | leave the status line alone |
| `-y`, `--yes` | answer yes to questions |

### ccseat init

```text
ccseat init <zsh|bash|fish>
```

Prints the shell integration, which defines in interactive shells only:

- a `claude` function that goes through ccseat, so `claude` opens the current seat and switches at a limit,
- the shortcut `cc`: with no arguments it opens the picker, like `ccseat`; with arguments it runs your real `cc`, so the C compiler keeps working (without a compiler installed, `cc <command>` runs `ccseat <command>`). The name comes from the [`shortcut` setting](configuration.md#settings): with any other name, such as `ccseat config shortcut cs`, the shortcut with arguments runs `ccseat` with them, and `off` defines none. A function or alias of that name that you made yourself is left alone,
- tab completion for ccseat's commands and your seat names.

`ccseat setup` adds the right line for you; to add it by hand:

```sh
eval "$(ccseat init zsh)"      # ~/.zshrc
eval "$(ccseat init bash)"     # ~/.bashrc, or ~/.bash_profile on macOS
ccseat init fish | source      # ~/.config/fish/config.fish
```

### ccseat statusline

```text
ccseat statusline [install | uninstall] [--seat <seat>] [-q]
```

The status line Claude Code shows under its prompt: the seat, model, folder, context and both usage limits, plus what is running while a workflow or agent works. See [Status line](usage.md#status-line).

| Form | What it does |
|---|---|
| `ccseat statusline` | render it; Claude Code runs this and sends the session details on stdin, and in a terminal it prints a preview |
| `ccseat statusline install` | set it in `~/.claude/settings.json`, which every seat shares, after saving a timestamped backup; a status line you had is kept |
| `ccseat statusline uninstall` | remove it and put back the previous one |
| `--seat <seat>` | use that seat's own `settings.json` instead, for a seat that does not share settings |
| `-q`, `--quiet` | print nothing on success |

### ccseat progress

```text
ccseat progress [--line | --tsv | --agents] [session_id]
```

The workflows and agents still running in a Claude Code session. The session defaults to `$CLAUDE_CODE_SESSION_ID`, which Claude Code sets inside a session; without one, the readable view covers every session. It only reads files.

| Option | What it does |
|---|---|
| (none) | a readable summary |
| `--line` | one compact line, nothing when idle |
| `--tsv` | one tab-separated row per running workflow: name, phase index, phase count, phase title, agents finished, started, running and failed, minutes since start, agents started and finished in this phase |
| `--agents` | one tab-separated row per running agent: kind (`wf`, `bg` or `fg`), workflow name, label, agent type, tool calls, last tool, idle seconds, minutes alive |

### ccseat doctor

```text
ccseat doctor
```

Checks the tools ccseat needs, every seat (login, shared links, MCP servers), the shell integration and the status line, and prints the fix for anything that is off. It changes nothing except refreshing the usage cache. See [Troubleshooting](troubleshooting.md).

### ccseat config

```text
ccseat config [setting [value]]
```

Without arguments, prints every setting. With a setting, prints its value. With a value, changes it, and the value `default` puts the default back. The settings are listed in [Configuration](configuration.md#settings).

```sh
ccseat config limit_5h 90
ccseat config shortcut cs      # the picker shortcut is cs instead of cc (open a new terminal)
ccseat config share default
```

### ccseat uninstall

```text
ccseat uninstall [--purge] [-y]
```

Removes the shell integration, the status line (when it points at ccseat) and the program. Seats, their logins and `~/.claude` stay. See [Uninstalling](installation.md#uninstalling).

| Option | What it does |
|---|---|
| `--purge` | also sign out every seat except `~/.claude`, and move the seat folders and ccseat's settings and cache to the Trash |
| `-y`, `--yes` | do not ask for confirmation |

### ccseat help

```text
ccseat help [command]
```

Help for ccseat, or for one command. `-h` and `--help` work too, also after a command: `ccseat add --help`.

### ccseat version

```text
ccseat version
```

Prints the version. `--version` and `-v` work too.
