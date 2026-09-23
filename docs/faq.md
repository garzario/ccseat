# FAQ

- [Is this allowed?](#is-this-allowed)
- [Is it safe?](#is-it-safe)
- [Will it change my existing Claude Code setup?](#will-it-change-my-existing-claude-code-setup)
- [Does it work on Linux? On Windows?](#does-it-work-on-linux-on-windows)
- [Is there a limit on how many accounts I can add?](#is-there-a-limit-on-how-many-accounts-i-can-add)
- [Can I continue a conversation on another account?](#can-i-continue-a-conversation-on-another-account)
- [Can I keep a seat isolated?](#can-i-keep-a-seat-isolated)
- [Do editors and scripts use ccseat?](#do-editors-and-scripts-use-ccseat)
- [Can I use ccseat without the shell integration?](#can-i-use-ccseat-without-the-shell-integration)
- [Does the cc shortcut break my C compiler?](#does-the-cc-shortcut-break-my-c-compiler)
- [What does LIMIT REACHED mean?](#what-does-limit-reached-mean)
- [What if Anthropic changes the usage endpoint?](#what-if-anthropic-changes-the-usage-endpoint)
- [How do I update or uninstall?](#how-do-i-update-or-uninstall)

## Is this allowed?

ccseat is for people who have more than one Claude account of their own, for example a personal plan and a work plan. It does not get around any limit: each account keeps its own 5-hour and weekly limits, and every seat is an ordinary Claude Code login made by `claude auth login`. Use it only with accounts that are yours, follow Anthropic's terms for each of them, and never share an account or a login with anyone else.

## Is it safe?

ccseat runs only on your computer. It reads the login Claude Code already stored, only to ask Anthropic's usage endpoint how much of each limit is left, and never prints, logs or saves a token. It never deletes your data: a removed seat goes to the Trash, and a file it replaces is kept in a backup first. The only files it removes outright are its own, and empty files or exact copies that a shared link replaces. See [Is it safe?](../README.md#is-it-safe) in the README, [Logins and credentials](how-it-works.md#logins-and-credentials), and the [security policy](../.github/SECURITY.md).

## Will it change my existing Claude Code setup?

Very little. Your `~/.claude` folder becomes the primary seat and keeps working exactly as before, also for plain `claude` and your editor. ccseat adds empty folders and files to it for shared items it does not have yet, so every seat's links are valid, and it edits `~/.claude/settings.json` only when you run `ccseat statusline install` or `uninstall`. The one exception is `ccseat add --dir`, which moves or copies a folder's own skills, conversations and other entries into `~/.claude` so every seat can use them; [Adopting an existing folder](how-it-works.md#adopting-an-existing-folder) explains it.

## Does it work on Linux? On Windows?

Linux, yes. It needs bash, `jq` and `curl`, as on macOS. Logins are read from each seat's `.credentials.json`, and removed seats go to `~/.local/share/Trash`, where your file manager can restore them. CI runs the test suite on Ubuntu and macOS for every change.

Windows is not supported or tested.

## Is there a limit on how many accounts I can add?

No. Add one seat per account. When they do not fit in the terminal, the picker shows one line per seat and scrolls. The number keys open the first nine, and every seat can be reached with the arrow keys or opened by name.

## Can I continue a conversation on another account?

Yes. Conversations are shared, so `claude --resume` (or `ccseat run work --resume`) in the same folder lists the sessions of every seat.

## Can I keep a seat isolated?

What is shared is the same for every seat. To share less, shorten the list; ccseat removes the links it made for the rest, and `ccseat config share default` brings them back:

```sh
ccseat config share settings.json,CLAUDE.md,skills
```

To give one seat its own copy of one item, point that seat's link somewhere else. ccseat keeps a link you point elsewhere, and `ccseat sync` lists it as kept:

```sh
dir=$(ccseat usage work --json | jq -r .dir)   # the folder of the seat work
ln -sfn ~/notes/work-CLAUDE.md "$dir/CLAUDE.md"
```

Do this only for a seat ccseat added, never for the primary seat: in `~/.claude` the command would replace your real file.

For an account that shares nothing at all, do not add it as a seat, and open it yourself with `CLAUDE_CONFIG_DIR=~/claude-private claude`. ccseat opens folders it does not know exactly as asked.

## Do editors and scripts use ccseat?

Only commands that go through the `claude` shell function or `ccseat` do. The shell function exists in interactive shells only, so editor extensions and scripts that start Claude Code by themselves keep using `~/.claude`, or whatever `CLAUDE_CONFIG_DIR` they are given.

## Can I use ccseat without the shell integration?

Yes. `ccseat` (the picker), `ccseat run <seat>` and every other command work on their own. Without the shell integration you only miss the `claude` function that switches seats by itself, the `cc` shortcut and tab completion.

## Does the cc shortcut break my C compiler?

No. `cc` with no arguments opens the picker, and `cc` with any arguments runs your real C compiler, exactly as before, so `cc -o hello hello.c` still works. The shortcut exists in interactive shells only, so `make`, build scripts and editors call the compiler directly and never see it. If you already have a `cc` function or alias of your own, ccseat leaves it alone.

Rather keep `cc` untouched? Pick another name or none, then open a new terminal:

```sh
ccseat config shortcut cs     # or: ccseat config shortcut off
```

## What does LIMIT REACHED mean?

The seat is out for now: its 5-hour usage is at `limit_5h` (95% by default) or more, or its weekly usage is at `limit_weekly` (100% by default) or more. The picker, `ccseat list` and the status line show it in bold red with the time the seat comes back. `claude` moves to a seat with room by itself, and you can still open an out seat on purpose: the picker asks first, and `ccseat run` warns in one line. [When a seat is out](usage.md#when-a-seat-is-out-limit-reached) has the details.

## What if Anthropic changes the usage endpoint?

ccseat asks `https://api.anthropic.com/api/oauth/usage` for the numbers. That endpoint is not documented and may change at any time. If it does, seats still open and everything else keeps working, but ccseat shows no usage and cannot switch at a limit until it is updated.

## How do I update or uninstall?

See [Updating](installation.md#updating) and [Uninstalling](installation.md#uninstalling). In short: run the installer again (or `brew upgrade ccseat`, or `git pull` in a clone) to update, and `ccseat uninstall` to remove it. Your seats stay unless you pass `--purge`, and `~/.claude` always stays.
