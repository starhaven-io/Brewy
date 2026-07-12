# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately by emailing
[security@starhaven.io](mailto:security@starhaven.io) or using
[GitHub's private vulnerability reporting](https://github.com/starhaven-io/Brewy/security/advisories/new).
Do not open a public issue for an undisclosed vulnerability.

Useful reports include:

- Affected Brewy version or commit.
- macOS version and processor architecture.
- Homebrew path and relevant `brew` or `mas` version.
- Steps to reproduce and the security impact.
- Any suggested mitigation or fix.
- Logs or command output with secrets, tokens, and local private paths removed.

Brewy executes the user's local Homebrew installation and displays package, tap,
appcast, and release-note metadata from external sources. Vulnerabilities in
individual formulae, casks, taps, or upstream packages should usually be reported
to the upstream project or tap maintainer unless Brewy changes the security
impact.

We will acknowledge the report, investigate it, and coordinate disclosure with
you.

## Supported versions

Security fixes are made against the current `main` branch and the latest released
version of Brewy.
