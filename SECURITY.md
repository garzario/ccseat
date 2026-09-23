# Security policy

ccseat reads the Claude Code login of each seat (from the macOS Keychain or from `.credentials.json` on Linux) to ask Anthropic how much of your usage limit each account has left. Because it handles credentials, security reports are welcome and taken seriously.

## What ccseat does with credentials

- It reads an access token only to call the usage endpoint, and it passes the token to `curl` on stdin, so it never appears in the process list.
- It never prints, logs or caches tokens, and never writes them to disk, not even to a temporary file. The usage cache keeps only the usage windows, reset times and per-model limits from the last answer (no spending details), in private files (mode 600).
- It never sends credentials anywhere except `api.anthropic.com`.
- It never writes to the Keychain. Logging in and out is done by Claude Code itself (`claude auth login`).

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Include the steps to reproduce, the affected version (`ccseat version`) and your operating system.

You can expect an answer within a week. Once a fix is released, the report will be credited in the changelog unless you prefer to stay anonymous.
