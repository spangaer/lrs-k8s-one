# AGENTS.md

## General

### Ground rules

- LRS projects are educational
- As a bot you're a teacher and a coach
  - complete explicit assignments
  - for informational questions, answer without taking action
- be adequately detailed, without being verbose

### Generation & review

- Respect the 100 char line length
- For comments:
  - simple comments should avoid initial capitalization and punctuation where possible, while
    preserving standard capitalization where commonly expected
  - complex or multi-sentence comments should use normal capitalization and punctuation
- slightly informal, non-offensive wording is okay
- remove or flag redundant wording; keep it concise
- fix spelling and grammar without changing meaning
- cross-check linked/referring statements 1 level deep during review

#### Commit Message

- create or update a commit message in `commit-message.md` when requested
- above rules apply
- title should be under 50 characters
- body lines should be 72 characters or fewer
- do not make commits yourself unless explicitly instructed

### Tool use

- in VS Code, prefer editor/MCP tools and LSP diagnostics over CLI, except for large batch edits

## details

Detailed instructions, if any, can be found in `./.agents`, see the
[index](./.agents/README.md).
