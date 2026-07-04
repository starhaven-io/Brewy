# Security Policy

## Supported Versions

Security fixes are made against the current `main` branch and the latest released
version of Brewy.

## Reporting a Vulnerability

Please do not report security vulnerabilities in a public issue.

Use GitHub private vulnerability reporting for this repository:

https://github.com/starhaven-io/Brewy/security/advisories/new

If private vulnerability reporting is unavailable, open a public issue with no
technical details and ask for a private contact path.

Helpful reports include:

- Affected Brewy version or commit.
- macOS version and processor architecture.
- Homebrew path and relevant `brew` or `mas` version.
- Steps to reproduce and the security impact.
- Logs or command output with secrets, tokens, and local private paths removed.

Brewy executes the user's local Homebrew installation and displays package, tap,
appcast, and release-note metadata from external sources. Vulnerabilities in
individual formulae, casks, taps, or upstream packages should usually be reported
to the upstream project or tap maintainer unless Brewy changes the security
impact.

We will acknowledge private reports as soon as practical, investigate the issue,
and coordinate disclosure timing with the reporter when a fix is needed.
