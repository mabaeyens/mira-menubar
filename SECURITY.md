# Security Policy

## Supported versions

{{PROJECT_NAME}} is a single-maintainer project. Only the latest release (and the current `main`)
is supported. Reproduce any issue on the current version before reporting.

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Report privately through GitHub:

1. Go to the [Security](https://github.com/{{GITHUB_USER}}/{{PROJECT_NAME}}/security) tab of this repo.
2. Click **Report a vulnerability**.
3. Describe the issue.

Helpful details: the impact, steps to reproduce (or a proof of concept), your OS and tool
versions, and the {{PROJECT_NAME}} version.

I acknowledge reports on a best-effort basis; as a one-person project, response times vary. Once a
fix ships, the advisory can be published to credit the reporter. Say so if you prefer to stay
anonymous.

## Scope

- {{What the project trusts, what it never sends off-device, how secrets and tokens are handled.}}
- User input is validated against command injection and path traversal. Reports of gaps here
  are especially welcome.
