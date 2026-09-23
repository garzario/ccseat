# Security policy

ccseat reads the Claude Code login of each seat (from the macOS Keychain or from `.credentials.json` on Linux) to ask Anthropic how much of your usage limit each account has left. Because it handles credentials, security reports are welcome and taken seriously.

## What ccseat does with credentials

- It reads an access token only to call the usage endpoint, and it passes the token to `curl` on stdin, so it never appears in the process list.
- It never prints, logs or caches tokens, and never writes them to disk, not even to a temporary file. The usage cache keeps only the usage windows, reset times and per-model limits from the last answer (no spending details), in private files (mode 600).
- It never sends credentials anywhere except `api.anthropic.com`. It sends the token, the headers `Accept`, `Content-Type`, `anthropic-beta: oauth-2025-04-20` and `User-Agent: claude-code/2.1.280`, and no body.
- A token that holds a quote, a backslash or a line break is never sent, so it cannot add options to that request.
- It never writes to the Keychain. Logging in and out is done by Claude Code itself (`claude auth login`).

## Network and tracing

- **curl runs with `-q` and allows https only.** Every request ccseat makes, and every download the installer makes, starts curl with `-q`, so a `~/.curlrc` is never read: an `insecure`, `trace` or `proxy` line there cannot turn off certificate checks or expose a token. Each of these requests allows https only, redirects included.
- **A `bash -x` trace never shows a token.** The functions that hold a login in variables run with tracing paused, so pasting a trace into a bug report never leaks a login.

## The installer

- **It verifies the published checksums.** By default the one-line installer installs the latest release and checks the download against the `SHA256SUMS` file published with that release. A checksum that does not match, or a published checksum file that cannot be downloaded or read, stops the install before anything is written. A release without a `SHA256SUMS` file is installed with a note that says so, and `--ref main` (the development version) has no published checksum.
- It refuses a `--ref` with `..` in it, so the download cannot point outside this repository.
- It never uses `sudo`, and it asks before it adds its one marked block to your shell startup file.

## Other guarantees

- The usage cache and its error files are read only as regular files, never through a link.
- Files and folders ccseat creates in `~/.claude` and in its own folders are private (mode 600 or 700).
- Seat names and email addresses are printed without terminal control characters, and a hand-edited seat name cannot run code through tab completion.
- `ccseat add --dir` refuses a git repository, a folder inside one and a project's `.claude` folder, and `ccseat remove` and `ccseat uninstall` move folders to the Trash instead of deleting them.

## What you should know

- **`ccseat add --dir` is only for folders you made yourself.** A Claude Code config folder can run commands through its hooks and MCP servers, and its skills and agents are copied into `~/.claude`, where every seat uses them. Adopting a folder from someone else is like running their code.
- The usage endpoint ccseat asks is not documented by Anthropic and may change at any time.

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please report privately through GitHub: [open a private report](https://github.com/garzario/ccseat/security/advisories/new), or open the repository's **Security** tab and choose **Report a vulnerability**. Include the steps to reproduce, the affected version (`ccseat version`) and your operating system. Please do not open a public issue.

You can expect an answer within a week. Once a fix is released, the report will be credited in the changelog unless you prefer to stay anonymous.
