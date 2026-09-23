# Installation

ccseat is a bash program plus a folder of library files. Pick one way to install it, then turn on the shell integration so that `claude` goes through ccseat.

- [Requirements](#requirements)
- [One-line installer](#one-line-installer)
- [Homebrew](#homebrew)
- [From a clone](#from-a-clone)
- [With make](#with-make)
- [The shell integration](#the-shell-integration)
- [Updating](#updating)
- [Uninstalling](#uninstalling)

## Requirements

- macOS or Linux
- bash: the `/bin/bash` 3.2 that macOS ships is fine, and so is bash 5
- `jq` and `curl`
- [Claude Code](https://github.com/anthropics/claude-code), the `claude` command
- zsh, bash or fish for the shell integration

The installer and `ccseat doctor` check for each of these and print the exact command that installs anything missing. ccseat never installs dependencies by itself.

## One-line installer

```sh
curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash
```

Then open a new terminal. **The installer installs the latest release by default.** Add `--ref main` for the development version, or `--ref vX.Y.Z` for a particular tag (see [the options](#installer-options)). It:

1. downloads ccseat (the latest release, or what `--ref` names), checks a release against its published `SHA256SUMS` when there is one, installs it into `~/.local/share/ccseat/app` and links `~/.local/bin/ccseat` to it. It never uses `sudo`.
2. checks for `jq`, `curl` and Claude Code, and prints the install command for anything missing.
3. shows the block it wants to add to your shell startup file and asks before adding it. The file is `~/.zshrc` for zsh, `~/.bash_profile` for bash on macOS, `~/.bashrc` for bash on Linux, or `~/.config/fish/conf.d/ccseat.fish` for fish. The block also puts `~/.local/bin` on your `PATH` when it is not there yet.

If you skip the shell step, run `ccseat setup` later.

### Installer options

Options go after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash -s -- --no-shell
```

| Option | What it does |
|---|---|
| `-y`, `--yes` | add the shell block without asking (same as `CCSEAT_YES=1`) |
| `--no-shell` | leave your shell startup files alone |
| `--shell zsh\|bash\|fish` | set up that shell instead of the one in `$SHELL` |
| `--prefix DIR` | link the command into `DIR/bin` (default `~/.local`) |
| `--ref REF` | what to install: `latest` (the latest release, the default), a tag such as `v0.2.0`, or `main` for the development version (any branch or commit works; also `CCSEAT_REF`) |
| `--download` | download even when the script runs from a clone |
| `--uninstall` | remove what the installer added; your seats stay |
| `-h`, `--help` | print the options |

To install a particular release (`--ref vX.Y.Z`, a tag), or the development version (`--ref main`):

```sh
curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash -s -- --ref v0.2.0
curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash -s -- --ref main
```

The script itself always comes from `main`, but what it installs is the latest release unless you pass `--ref`.

Every download goes over https only, and the installer ignores `~/.curlrc`. A release is checked against its `SHA256SUMS` file: a checksum that does not match, or a checksum file that cannot be read, stops the install before anything is written. A branch or a commit has no published checksum.

## Homebrew

This repository is also a Homebrew tap:

```sh
brew tap garzario/ccseat https://github.com/garzario/ccseat
brew install ccseat
ccseat setup        # adds the shell integration (asks first)
```

Homebrew installs `jq` for you. Claude Code itself is not a Homebrew dependency; install it with `curl -fsSL https://claude.ai/install.sh | bash` if you do not have it yet.

## From a clone

```sh
git clone https://github.com/garzario/ccseat
cd ccseat
./install.sh
```

From a clone, `install.sh` links `~/.local/bin/ccseat` to the clone instead of downloading, so a `git pull` updates ccseat. It takes the same options as the one-line installer.

## With make

`make install` copies the program into a prefix, which suits packagers and people who manage `/usr/local` by hand:

```sh
make install PREFIX="$HOME/.local"   # or: sudo make install (into /usr/local)
~/.local/bin/ccseat setup            # adds the shell integration
```

The program and its library go to `$(PREFIX)/share/ccseat`, and `$(PREFIX)/bin/ccseat` links to it. `DESTDIR` stages the install for a package. `make uninstall` with the same `PREFIX` removes it again.

## The shell integration

The installer and `ccseat setup` add one marked block to your shell startup file:

```sh
# >>> ccseat >>>
if command -v ccseat >/dev/null 2>&1; then eval "$(ccseat init zsh)"; fi
# <<< ccseat <<<
```

To add it by hand instead, put one of these lines in your startup file:

```sh
eval "$(ccseat init zsh)"      # ~/.zshrc
eval "$(ccseat init bash)"     # ~/.bashrc, or ~/.bash_profile on macOS
ccseat init fish | source      # ~/.config/fish/config.fish
```

In interactive shells only, it defines:

- a `claude` function that runs `ccseat claude`, so `claude` opens your current seat and switches seats at a limit (see [Auto-switch](usage.md#auto-switch)),
- `cc`, the shortcut for the picker: `cc` with no arguments opens it, and `cc` with arguments runs your real `cc`, so the C compiler keeps working. The [`shortcut` setting](configuration.md#the-shortcut) picks another name (`ccseat config shortcut cs`) or none (`off`), and a function or alias of that name that you made yourself is left alone,
- tab completion for ccseat's commands and your seat names.

Scripts, editors and build tools are not affected: they keep running Claude Code, and `cc`, directly.

## Updating

| Installed with | Update with |
|---|---|
| the one-line installer | run the same line again; it installs the latest release and replaces `~/.local/share/ccseat/app` |
| Homebrew | `brew upgrade ccseat` |
| a clone | `git pull` in the clone |
| `make install` | `git pull`, then `make install` again with the same `PREFIX` |

Updating never touches your seats or settings. `ccseat version` prints the version you have, and [CHANGELOG.md](../CHANGELOG.md) lists what changed.

## Uninstalling

```sh
ccseat uninstall            # the shell integration, the status line and the program; seats stay
ccseat uninstall --purge    # also signs out every seat except ~/.claude and moves the seat
                            # folders and ccseat's settings and cache to the Trash
```

`ccseat uninstall` asks first (`-y` skips the question). It removes the shell block, and the one-line `ccseat init` lines shown above, from your startup files and keeps a copy of each file it edits in the Trash. A `ccseat init` line inside an `if` you wrote yourself stays, and ccseat names it for you to remove. It also puts back the status line you had before `ccseat statusline install`, and removes the program. A clone is left in place. Your `~/.claude` folder and its login always stay.

If ccseat was installed with Homebrew, run `ccseat uninstall` first and then `brew uninstall ccseat`. If the `ccseat` command is already gone, the installer can clean up what it added:

```sh
curl -fsSL https://raw.githubusercontent.com/garzario/ccseat/main/install.sh | bash -s -- --uninstall
```
