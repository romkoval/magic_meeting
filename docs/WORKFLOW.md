# Development workflow

Work is done by agents; the main session is the orchestrator. It owns the plan,
splits it into tasks, runs the agents, merges their work, and is the only one
that pushes.

## Per stage of the TZ (§11)

1. **Plan.** `planner` reads the TZ section and the code and writes
   `docs/plans/stage-N-<name>.md`: exact files, types and signatures, the order
   of tasks, which tasks can run in parallel, tests per task, risks.
   The orchestrator checks it against the TZ and commits it.
2. **Implement.** One implementer agent per task, each in its own git worktree.
   Tasks that touch disjoint files run in parallel; the plan fixes the
   interfaces between them up front. Each implementer writes the tests for its task.
3. **Integrate.** The orchestrator merges the worktrees into the stage branch,
   resolves conflicts, runs Go checks locally.
4. **Review.** In parallel on the integrated diff: `swift-reviewer`,
   `silent-failure-hunter`, plus `go-reviewer` / `security-reviewer` when the
   proxy or anything handling user content changed. Only findings with a
   concrete failure scenario are acted on.
5. **Fix and verify.** Fixes go back to an implementer (or the orchestrator for
   one-liners). Push; CI must be green. A red iOS build goes to
   `swift-build-resolver` with the CI log.
6. **Report.** Short summary to the owner: what was built, what is not yet
   verified (anything that needs a real iPhone), open questions.

## Rules

- No agent pushes or opens pull requests; the orchestrator does.
- Swift cannot be compiled in the container, so CI is the gate for every push.
- Anything that needs a device (microphone, background audio, calls, Share
  Extension) is listed as "verify on iPhone" in the stage report.
