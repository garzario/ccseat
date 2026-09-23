# Changelog

All notable changes to ccseat are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/garzario/ccseat/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/garzario/ccseat/releases/tag/v0.1.0
