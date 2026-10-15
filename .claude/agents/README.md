# Agents

Taken unmodified from [Everything Claude Code](https://github.com/affaan-m/everything-claude-code)
(`agents/`, commit `76aaa77`), MIT licence, see `LICENSE-ECC`.

| Agent | Role in this repo |
|---|---|
| `planner` | Turns a stage of the TZ into a step plan in `docs/plans/` |
| `swift-reviewer` | Reviews every Swift change |
| `go-reviewer` | Reviews every proxy change |
| `silent-failure-hunter` | Looks for swallowed errors, mostly `try?` and empty catches |
| `security-reviewer` | Proxy endpoints, prompts, anything that touches user content or keys |
| `swift-build-resolver` | Fixes red iOS CI builds |

The agents assume a local toolchain. Read `CLAUDE.md` for what actually runs
where in this project; it overrides the agents' diagnostic commands.
