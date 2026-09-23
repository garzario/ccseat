# How it works

ccseat does not replace or patch Claude Code. It uses one thing Claude Code already supports: the `CLAUDE_CONFIG_DIR` variable, which tells Claude Code to keep its login, settings and history in a folder other than `~/.claude`. A seat is one such folder with its own login, and ccseat makes every seat share one setup.

- [Seats in one picture](#seats-in-one-picture)
- [What is shared](#what-is-shared)
- [Adopting an existing folder](#adopting-an-existing-folder)
- [Logins and credentials](#logins-and-credentials)
- [Usage numbers](#usage-numbers)
- [How claude picks a seat](#how-claude-picks-a-seat)
- [Removing and uninstalling](#removing-and-uninstalling)
- [Code map](#code-map)

## Seats in one picture

```text
                    ~/.claude   (the primary seat: your existing folder)
                    +----------------------------------------+
                    |  settings.json   CLAUDE.md   skills/   |
                    |  agents/   commands/   hooks/   ...    |   the real files,
                    |  projects/   history.jsonl             |   one copy for all
                    |----------------------------------------|
                    |  login, sessions, caches: its own      |
                    +----------------------------------------+
                          ^                          ^
                symlinks  |                          |  symlinks
                          |                          |
  +-----------------------+---------+  +-------------+-------------------+
  |  seats/seat (work)              |  |  seats/seat-2 (personal)        |
  |  settings.json -> ~/.claude/... |  |  settings.json -> ~/.claude/... |
  |  skills/       -> ~/.claude/... |  |  skills/       -> ~/.claude/... |
  |  ...                            |  |  ...                            |
  |---------------------------------|  |---------------------------------|
  |  login, sessions, caches: own   |  |  login, sessions, caches: own   |
  |  .claude.json: own copy         |  |  .claude.json: own copy         |
  +---------------------------------+  +---------------------------------+

  seats/ is ~/.local/share/ccseat/seats/
```

- **The primary seat** is your existing `~/.claude`. ccseat opens it with `CLAUDE_CONFIG_DIR` unset, exactly like plain `claude`, so editors and scripts that start Claude Code by themselves keep using it. It is never removed.
- **Other seats** are private folders in `~/.local/share/ccseat/seats/`, opened with `CLAUDE_CONFIG_DIR` set to them. A folder you already had, like `~/.claude-work`, can be a seat too.
- **Folder names** are set when `ccseat add` creates the folder: after `--name` or the email you gave, otherwise `seat`, `seat-2` and so on. Renaming a seat never moves its folder, so the login keeps working; `ccseat current --dir` or `ccseat list --json` shows where each seat lives.
- **Shared items** in each seat are symlinks into `~/.claude`, so there is one copy of each, and a change in one seat shows up in all of them.

## What is shared

**Linked** into `~/.claude` (the `share` setting, see [Configuration](configuration.md#what-every-seat-shares)):

| Item | What it is |
|---|---|
| `settings.json` | your Claude Code settings |
| `CLAUDE.md` | your memory file |
| `skills`, `agents`, `commands`, `rules`, `hooks`, `output-styles`, `plugins` | your extensions |
| `projects` | conversations and project memory, so `claude --resume` works from any seat |
| `file-history` | rewind checkpoints |
| `plans`, `todos` | plans and todo lists |
| `history.jsonl` | prompt history |

Status line scripts that your `settings.json` runs from inside `~/.claude` are linked too. When `~/.claude` lacks a shared item, ccseat creates it (an empty folder, an empty file, or `{}` for `settings.json`), so every link is valid.

**Never shared**, whatever the `share` setting says: the login (`.credentials.json`), `.claude.json`, sessions, caches, telemetry, IDE state and the other per-account state Claude Code keeps.

**Copied instead of linked:** each seat has its own `.claude.json`, because Claude Code keeps the account in it. ccseat copies into it, from `~/.claude.json`:

- your MCP servers (servers a seat added on its own stay; servers ccseat copied and you later removed from `~/.claude.json` go away),
- the folders you marked as trusted,
- the onboarding flag and theme, so a new seat skips Claude Code's first-run setup.

This copy runs silently every time a seat opens, and `ccseat sync` runs it by hand.

## Adopting an existing folder

`ccseat add --dir ~/.claude-work` turns a folder you already use into a seat.

> [!WARNING]
> Use `--dir` only on folders you made yourself. A Claude Code config folder is not just data: its hooks and MCP servers run commands on your computer, and its skills and agents are copied into `~/.claude`, where every seat uses them. Adopting a folder from someone else is like running their code.

Nothing in the folder is lost:

- When `~/.claude` lacks an item the folder has (say `output-styles`), the folder's copy moves into `~/.claude` and becomes the shared one.
- When both have a folder like `skills` or `projects`, the entries `~/.claude` lacks are copied into it, so your conversations and skills stay available from every seat. Nothing is overwritten.
- The folder's own copies of shared items, such as its `settings.json`, move to `.ccseat-backup/<date>/` inside the seat, and the links take their place. Only empty files and folders, and exact copies of what `~/.claude` already has, are dropped.

ccseat says what it did in a few lines:

```text
$ ccseat add --dir ~/.claude-work
Added bob (bob@example.com).
  It now shares settings.json, skills and projects with ~/.claude. Its own
  copies were moved to ~/.claude-work/.ccseat-backup/20260923-020050
  Moved its output-styles to ~/.claude, which had none, so every seat shares
  it now.
  Copied 1 skill and 1 project that ~/.claude did not have.
Open it with: ccseat run bob
```

It refuses folders that must never be a seat folder: your home folder, a folder inside `~/.claude` or one that holds it, ccseat's own folders, a git repository or any folder inside one (a home folder kept in git is fine), a project's `.claude` folder, and folders whose content does not look like a Claude Code config folder. A folder counts as one when it is empty or new, holds a login, or holds files Claude Code itself writes there (`.claude.json` or the older `.config.json`, `.credentials.json`, `statsig`, `sessions` or `shell-snapshots`); `CLAUDE.md`, `settings.json` or `projects` alone are not enough, since many repositories have them. `~/.claude` itself, even through a link, becomes the primary seat.

## Logins and credentials

Logins stay exactly where Claude Code puts them, and ccseat only reads them:

| Platform | Where Claude Code keeps the login |
|---|---|
| macOS | the Keychain, as `Claude Code-credentials` for `~/.claude`, and `Claude Code-credentials-<8 hex characters>` for any other folder (the first 8 characters of a SHA-256 of the folder's path) |
| Linux | `<seat folder>/.credentials.json` |

Signing in and out is always done by Claude Code itself: `ccseat add` runs `claude auth login` in the new seat, and `ccseat remove` runs `claude auth logout`. ccseat never writes to the Keychain.

It reads a seat's login for two things: to tell whether the seat is signed in, and to ask for its usage. The access token stays in shell variables and pipes. It is never printed, logged, cached or written to disk (not even to a temporary file), and it goes to `curl` on standard input, so it never appears in the process list. The [security policy](../.github/SECURITY.md) has the full list of guarantees.

## Usage numbers

- **Where they come from:** `https://api.anthropic.com/api/oauth/usage`, asked with each seat's own login. This is the one network request ccseat makes. **The endpoint is not documented and may change at any time.** If it does, seats still open, but ccseat shows no usage and cannot switch at a limit.
- **What is sent:** one `GET` per seat, at most once a minute, with that seat's bearer token and the headers `Accept`, `Content-Type`, `anthropic-beta: oauth-2025-04-20` and `User-Agent: claude-code/2.1.280` (the way Claude Code itself asks), and no body. curl runs with `-q`, so `~/.curlrc` is ignored, and allows https only, redirects included.
- **What is kept:** only the 5-hour and weekly windows, their reset times and any per-model weekly limits from the last answer, in private files in `~/.cache/ccseat`. Spending details and tokens are never stored.
- **How fresh:** numbers are fetched again when they are more than a minute old. `ccseat list` waits up to 6 seconds for fresh numbers; the picker draws the cached ones at once and refreshes behind them.
- **The status line helps:** Claude Code hands its status line the current rate limits, and ccseat saves them into the same cache, so the numbers of the seat you are working in stay fresh without extra requests. When a seat has no fresh answer, ccseat also reads the usage numbers Claude Code caches in the seat's `.claude.json`, whichever is newer.

## How claude picks a seat

```text
  you type:  claude --resume
                  |
                  v
  the claude shell function runs:  ccseat claude --resume
                  |
                  v
  CLAUDE_CONFIG_DIR set by you? ---- yes, not a seat's folder ---> open it as asked
                  |
                  |  starting seat: the seat of that folder,
                  |  or else the current seat
                  v
  starting seat at its limit? ------ no ----> open the starting seat
                  | yes
                  v
  another seat with room? ---------- yes ---> open the freest seat, print one line
                  | no
                  v
  open the seat that resets first
```

- **At its limit** means 5-hour usage at `limit_5h` (95% by default) or more, or weekly usage at `limit_weekly` (100%) or more. The same rule makes the picker, `ccseat list` and the status line show `LIMIT REACHED` (see [When a seat is out](usage.md#when-a-seat-is-out-limit-reached)).
- **Freest** means the lowest of each seat's higher percentage (5-hour or weekly). Seats without a login are skipped, a seat with no numbers yet counts as 99% used, and ties go to the seat listed first.
- **It never makes you wait:** the current seat's numbers are fetched in the foreground, for at most about 1.5 seconds, only when they are missing, more than 15 minutes old, or close to a limit. Everything else refreshes in the background.
- **The current seat does not change** when `claude` switches, so it goes back to your seat once that seat resets.
- **A `CLAUDE_CONFIG_DIR` you set yourself wins** over the current seat, so aliases like `CLAUDE_CONFIG_DIR=~/.claude-work claude` keep working.
- Subcommands that do not start a session (`claude mcp`, `claude auth`, `claude update` and similar) skip all of this and go straight to the current seat.

When nothing is set up yet (no seats, or `jq` missing), `claude` runs plain Claude Code. The wrapper never gets in the way.

## Removing and uninstalling

- `ccseat remove <seat>` signs the seat out and moves its folder to the Trash. On Linux that is the freedesktop Trash in `~/.local/share/Trash`, where your file manager can restore it. The primary seat is never removed.
- `ccseat uninstall` removes the shell block (a copy of each startup file goes to the Trash first), puts back the status line you had, and removes the program. Seats and `~/.claude` stay. `--purge` also signs out every seat except `~/.claude` and moves the seat folders and ccseat's settings and cache to the Trash.
- Outright, ccseat only removes files that are its own (its links, cache and lock files, backups of `settings.json` beyond the newest three, and the program when you uninstall), plus empty files or exact duplicates that a shared link replaces.

## Code map

ccseat is plain bash that runs on bash 3.2 and bash 5. `bin/ccseat` finds its library (following symlinks), loads it and runs the command.

| File | What it does |
|---|---|
| `bin/ccseat` | the entry point: loads the library, holds the help text and dispatches commands |
| `lib/ccseat/core.sh` | paths, settings, the seat list, colors, text layout, time formatting, messages, questions and the Trash |
| `lib/ccseat/auth.sh` | where each seat's login lives, whether it is signed in, which account it is, and finding the real `claude` |
| `lib/ccseat/usage.sh` | fetching and caching usage, limit checks, choosing the freest seat, and `ccseat usage` |
| `lib/ccseat/seats.sh` | the first run, `add`, `remove`, `rename`, `list`, `use`, `current`, `run`, `sync`, the shared links and the `claude` wrapper |
| `lib/ccseat/picker.sh` | the arrow-key picker |
| `lib/ccseat/shell.sh` | `ccseat init` (the `claude` function, the `cc` shortcut and completions), `ccseat setup` and `ccseat uninstall` |
| `lib/ccseat/statusline.sh` | the status line: drawing it, `install` and `uninstall` |
| `lib/ccseat/progress.sh` | `ccseat progress`: workflows and agents running in a session |
| `lib/ccseat/doctor.sh` | `ccseat doctor` |

[Development](development.md) covers the tests, the lint and how to add a command.
