# Changelog

All notable changes to ccseat are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-09-22

This release gives ccseat a shorter command, `cc`, makes a seat that is out
impossible to miss, and fixes security problems found in an audit of 0.1.0.
Everyone on 0.1.0 should update: run the one-line installer again,
`brew upgrade ccseat`, or `git pull` in a clone.

### Added

- `cc` opens the seat picker, like `ccseat`. With arguments it runs your real
  `cc`, so the C compiler keeps working (`cc -o hello hello.c`). The new
  `shortcut` setting gives it another name (`ccseat config shortcut cs`) or
  turns it off (`off`), and a function or alias of that name you made yourself
  is left alone.
- LIMIT REACHED: a seat at its 5-hour or weekly limit is hard to miss now. The
  picker shows `LIMIT REACHED` in bold red after its name with the time it
  comes back, turns the bar of that window red, dims the seat's other rows,
  and asks "Open it anyway? (y/N)" before it opens the seat. `ccseat list`
  and `ccseat usage` say `limit reached until <time>`, the status line says
  `LIMIT REACHED until <time>` before the seat to switch to, and
  `ccseat run` prints a one-line warning before it opens an out seat.
- Easy issue forms: a bug report needs only "What happened?" and a feature
  request only "What would you like?"; everything else is optional. New issues
  are titled `[Bug]` or `[Idea]` and labeled `needs triage`, blank issues are
  allowed, and links to report a bug, request a feature or ask a question sit
  under the README badges, in `SUPPORT.md` and in `CONTRIBUTING.md`.
- A way in for contributors: questions in GitHub Discussions, a support page,
  code owners for reviews, and Dependabot for the GitHub Actions that CI uses.
- A test that checks every link and image in the documentation.

### Changed

- The short command is `cc` instead of `cs`, and `cs` is no longer defined.
  To keep `cs`, run `ccseat config shortcut cs` and open a new terminal.
- The one-line installer installs the latest release by default instead of
  `main`. Add `--ref main` for the development version, or `--ref vX.Y.Z` for
  a particular tag.
- The documentation is reorganized into `docs/`: installation, usage,
  commands, configuration, how it works, FAQ, troubleshooting and development,
  with an index in `docs/README.md`, and `tests/README.md` explains how to
  write a test. The README is short now: a quick start, everyday use, the
  install options and a plain-words "Is it safe?" section.
  `CONTRIBUTING.md`, `SECURITY.md` and `CODE_OF_CONDUCT.md` moved to
  `.github/`, and the screenshots to `docs/assets/screenshots/`.
- A logo, in `docs/assets/logo/`, and a social preview image for GitHub.

### Security

- The usage request runs `curl -q`, so `~/.curlrc` cannot change it (an
  `insecure`, `trace` or `proxy` line there could expose a token), and it
  allows https only, redirects included. The installer's downloads do the
  same.
- A `bash -x` trace of ccseat never shows a token.
- The one-line installer installs the latest release instead of `main`, and
  checks it against the `SHA256SUMS` file published with the release. A
  checksum that does not match, or a checksum file that cannot be read, stops
  the install.
- The installer refuses a `--ref` with `..` in it, which could point the
  download outside this repository.
- `ccseat uninstall` never moves a shared prefix such as `~/.local` to the
  Trash (only ccseat's own files leave it), `--purge` leaves a `CCSEAT_HOME`
  that other programs use alone, and a git clone or worktree in the program's
  folder is never removed.
- A login whose token holds a quote or a line break is never sent, so it
  cannot add options to the usage request.
- A hand-edited seat name in the seats file cannot run code through tab
  completion.
- The block ccseat adds to a startup file escapes the folder it puts on
  `PATH`, so a folder name with `$`, a backquote or a quote stays text and
  never runs, and the fish integration quotes the program's path correctly.
- Adopting a folder with `ccseat add --dir` never writes through a link
  planted in its `.ccseat-backup` folder.
- `ccseat add --dir` refuses a git repository, a folder inside one, and a
  project's `.claude` folder. Before, a project could be adopted: its own
  `CLAUDE.md` and settings moved to a backup, a login and your MCP servers
  were written into it, and `ccseat remove` then moved the whole project to
  the Trash. A folder now counts as a Claude Code config folder only when it
  holds files Claude Code itself writes there, or a login. The documentation
  now says plainly that `--dir` is only for folders you made yourself.
- `ccseat usage --json` never follows a link in the usage cache.
- Terminal control characters in emails, plan names, seat names, workflow
  labels and agent types are stripped before they are printed.
- Files and folders ccseat creates in `~/.claude` (including the
  `settings.json` that `ccseat statusline install` creates) and the Trash
  folders it creates are private (mode 600 or 700).
- The status line turns off a repository's own `core.fsmonitor` command when
  it asks git for the branch.

### Fixed

- `ccseat uninstall` removes only the marked block and the one-line forms of
  `ccseat init` from your startup files. A `ccseat init` line inside an `if`
  you wrote yourself stays, and ccseat names its line, so the file never ends
  up with an empty `if` that bash refuses.
- `ccseat help config` and tab completion list the `statusline_width`
  setting, and the help of `setup` and `usage` lists every option.
- Running the tests from a git worktree or an unpacked release no longer
  moves the program under test to the Trash, and `make test` no longer prints
  "Terminated" notices on macOS.

## [0.1.0] - 2026-09-22

First release.

### Added

- Seats: one Claude Code config folder per account, each with its own login,
  sharing settings, memory (`CLAUDE.md`), skills, agents, commands, hooks,
  plugins, projects, file history and prompt history with your existing
  `~/.claude` through links.
- Your existing `~/.claude` becomes the first seat automatically when you are
  logged in there.
- `ccseat add` logs in to another account and names the seat after the email
  (the part before the `@`); `--email`, `--name` and `--dir` (adopt an existing
  folder) are supported. Add as many accounts as you like.
- `ccseat` (or `ccseat pick`) opens an arrow-key picker that shows each seat's
  5-hour and weekly usage with reset times, starting on the freest seat.
- `ccseat list [--json]`, `ccseat usage [seat] [--json] [--refresh]`,
  `ccseat use`, `ccseat current`, `ccseat run <seat>`, `ccseat rename`,
  `ccseat remove` (moves the folder to the Trash) and `ccseat sync` (MCP servers
  and trusted folders from your primary seat).
- `ccseat init zsh|bash|fish`: a `claude` wrapper that opens your current seat
  and, when it reaches its 5-hour or weekly limit, switches to the freest seat
  with a one-line notice; `cs` as a short alias. `ccseat setup` adds it to
  your shell startup file.
- `ccseat statusline` with `install` and `uninstall`: seat, model, effort,
  folder and branch, context, both usage limits and running workflows under the
  Claude Code prompt. `ccseat config statusline_width` (or `COLUMNS`) sets how
  wide it may get; when the next seat's name does not fit, it is named by number.
- `ccseat progress` for workflow and agent progress in a session.
- A `CLAUDE_CONFIG_DIR` you set yourself wins over the current seat, so
  existing aliases such as `CLAUDE_CONFIG_DIR=~/.claude-work claude` keep
  working; `claude mcp add --scope user` through the wrapper goes to
  `~/.claude` and reaches every seat.
- Weekly limits of a single model (for example "Opus weekly") in
  `ccseat usage`, `ccseat list --json` and the picker.
- `ccseat doctor`, `ccseat config`, `ccseat uninstall [--purge]`.
- One-line installer (`install.sh`), `make install`, a Homebrew formula, and a
  test suite that runs on macOS (bash 3.2) and Linux with stubbed `claude`,
  `curl` and Keychain.

[Unreleased]: https://github.com/garzario/ccseat/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/garzario/ccseat/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/garzario/ccseat/releases/tag/v0.1.0
