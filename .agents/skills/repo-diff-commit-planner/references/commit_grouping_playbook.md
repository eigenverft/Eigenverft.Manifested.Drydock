# Commit Grouping And Execution Playbook

## Commit-Readiness Checklist

- Verify each changed file belongs to a known intent.
- Exclude secrets, credentials, local-only files, and transient outputs.
- Confirm generated files are included only when intentionally required.
- Mark uncertain files as `needs-review` instead of forcing them into a commit.
- Separate `hold` and `needs-review` items from `commit-now` groups before staging.

## Logical Grouping Rules

- Group by one purpose per commit: feature, fix, refactor, docs, config, or tests.
- Keep unrelated modules or concerns in separate commits.
- Avoid mixing mechanical formatting with behavior changes unless inseparable.
- Ensure each group can stand on its own in history.

## Sequencing Checklist

- Apply schema or contract changes before dependent implementation.
- Apply implementation before downstream cleanup.
- Pair tests with the behavior they verify.
- Keep commit order bisect-friendly.

## Commit Message Guidance

- Subject line: imperative mood, concise, specific.
- Prefix the subject with the current local execution date in ISO format.
- Default format: `[YYYY-MM-DD] Imperative subject`
- Optional body: why the change exists, notable constraints, risks.
- Avoid vague subjects such as `update stuff` or `fixes`.

## Execution Checklist

- Stage only the files that belong to the current group.
- Use non-interactive `git add` and `git commit` commands.
- If git reports `.git/index.lock` or a likely concurrent-process lock, wait a few seconds and retry up to 3 times before treating it as a blocker.
- Prefer waiting over manual lock-file deletion during normal execution.
- Verify `git status` after each commit before proceeding.
- Run the relevant build or test command when it is part of commit validation.
- After all commit-ready groups are committed, attempt a normal `git push` unless the user explicitly said not to push.
- If push fails, summarize the likely reason from git output and do not escalate to force-push behavior.
- Stop if unexpected files appear or if the group boundaries no longer hold.

## Output Template

Use this template in responses, but keep it compact by default:

```markdown
Repository Change Summary
- <summary>

Commit Readiness
- commit-now:
  - <file or group>
- needs-review:
  - <file or group>
- hold:
  - <file or group>

Proposed Commit Groups
1. <group name>
   Rationale:
   - <reason>
   Commit message:
   - Subject: [YYYY-MM-DD] <imperative subject>
   - Body: <optional>

2. <group name>
   Rationale:
   - <reason>
   Commit message:
   - Subject: [YYYY-MM-DD] <imperative subject>
   - Body: <optional>

Execution Result
- Committed:
  - <commit hash> <subject>
- Push:
  - <push succeeded or short failure reason>
- Deferred:
  - <hold or needs-review item>

Deferred Items and Assumptions
- <item>
```

Prefer short grouped file summaries in prose unless a detailed file list is needed for safety or clarity.
