# Using this template

Delete this file once the checklist is done.

## 1. Create the repo

```bash
gh repo create mabaeyens/<name> --private --template mabaeyens/project-template --clone
```

Make it public later, once the README, LICENSE and SECURITY.md are filled in.

## 2. Fill the placeholders

Find every one with `grep -rn '{{' . --exclude-dir=.git --exclude=TEMPLATE.md`.

| Placeholder | Where | Value |
|---|---|---|
| `{{PROJECT_NAME}}` | README, CONTRIBUTING, SECURITY, CHANGELOG, bug report | Repo name |
| `{{ONE_LINE_DESCRIPTION}}` | README, CLAUDE.md | One sentence |
| `{{AUTHOR_NAME}}` | README, LICENSE, CODE_OF_CONDUCT | Copyright holder / byline |
| `{{GITHUB_USER}}` | SECURITY, bug report | GitHub login |
| `{{REQUIREMENT}}`, `{{PLATFORM}}`, `{{TEST_COMMAND}}`, `{{BUILD_COMMAND}}` | README, CONTRIBUTING, PR template | Project specifics |

## 3. Set up the local CLAUDE.md

`CLAUDE.md` is gitignored in every repo (local working guidance, not published).
The template ships `CLAUDE.md.template` so the structure is not lost:

```bash
cp CLAUDE.md.template CLAUDE.md
```

Fill it in, then `git rm --cached CLAUDE.md.template` if the project should not carry it.
Only actively worked projects keep a CLAUDE.md.

## 4. Pick the language sections

Both are marked optional. Delete what does not apply:

- `.gitignore`: the Python block or the Swift / Xcode block.
- `CLAUDE.md`: Python or Swift variants in Project Stack, Commands and Release.
- `CONTRIBUTING.md`: the Prerequisites and Setup lines.
- `.github/PULL_REQUEST_TEMPLATE.md`: the checklist lines for the other language.
- `src/`: rename or remove.

### Python only

```bash
uv python pin 3.13                      # before the first uv sync
UV_PROJECT_ENVIRONMENT="$HOME/.venvs/<project>" uv sync
ln -sfn "$HOME/.venvs/<project>" .venv  # keep the venv out of the tree
echo .venv >> .git/info/exclude         # a symlink is not matched by `.venv/`
```

Use `uv add` to add a dependency, not `uv sync`.

## 5. Repo hygiene

- [ ] README has the sections in order: title, description, requirements, setup, usage, workflow block, license, contributing.
- [ ] LICENSE year and holder filled in.
- [ ] At least 3 GitHub topics set.
- [ ] `specs/`, `notes/`, `SECURITY_AUDIT.md`, `CLAUDE.md` confirmed ignored (`git check-ignore -v <path>`).
- [ ] Private vulnerability reporting enabled (Settings, Code security).
- [ ] Add a row for the repo in the cross-repo standards table.

## Deliberately not included

CI workflows, a Makefile, a `scripts/` layout and `docs/` content are project-specific and appear in
only one or two repos. Add them when the project needs them.
