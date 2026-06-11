# Security policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please report vulnerabilities privately via GitHub: [Report a vulnerability](https://github.com/michael-palmes/SturtBar/security/advisories/new) (the repo's **Security** tab → **Report a vulnerability**). Do not open a public issue for anything security-sensitive.

You can expect an acknowledgement within a few days. If the report is valid, a fix ships in a new release and you will be credited in the advisory unless you prefer otherwise.

## Scope notes

SturtBar reads the Claude Code credentials already stored on your Mac (`~/.claude/.credentials.json` or the login keychain) and uses them to call the usage API. It never writes to Claude Code's credential stores; rotated tokens persist only to SturtBar's own keychain cache. Reports concerning credential handling, keychain access, or anything that could move data off the machine are especially welcome.
