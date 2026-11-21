# Contributing to {{PROJECT_NAME}}

Thanks for the interest. This is a single-maintainer project, so response times vary.

## Reporting bugs and requesting features

Open an issue using the bug report template. Security vulnerabilities go through
[SECURITY.md](SECURITY.md), not a public issue.

## Prerequisites

- {{e.g. Python 3.13 and uv   |   Xcode 26 and a recent macOS}}

## Setup

```bash
# {{commands to get a working checkout}}
```

Python: keep the virtualenv outside the tree and symlink it in:

```bash
uv python pin 3.13
UV_PROJECT_ENVIRONMENT="$HOME/.venvs/{{PROJECT_NAME}}" uv sync
ln -sfn "$HOME/.venvs/{{PROJECT_NAME}}" .venv
```

## Workflow

1. Fork and branch from `main`.
2. For anything beyond a small fix, write a short spec first (below).
3. Keep the change focused. Add or update tests.
4. Update README and CHANGELOG if the change is user-facing.

## The five-bullet spec

Specs live in `specs/<slug>.md`, which is gitignored (local only). Delete the file once the change
ships and the durable detail is in README or docs.

1. **Problem:** what is broken or missing
2. **Files:** which files to change and which functions to touch first
3. **Constraint:** a hard rule (don't show X if Y, match pattern Z)
4. **Edge cases:** (a) case 1, (b) case 2
5. **Done:** acceptance criteria (2 to 3 bullets)

## Before you open a pull request

- [ ] {{TEST_COMMAND}} passes
- [ ] No secrets, tokens or local config committed
- [ ] User input validated; no `shell=True` (Python)
- [ ] README / CHANGELOG updated if user-facing

## Pull request

Describe what changed and why, link the issue, and say how you tested it. Commit messages are
short and imperative. Do not add `Co-Authored-By:` trailers.
