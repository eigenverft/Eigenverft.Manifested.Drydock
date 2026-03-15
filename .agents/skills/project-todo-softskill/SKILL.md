---
name: project-todo-softskill
description: Softskill for maintaining a prioritized project-level PROJECT-TODO.md from the current request and recent conversation topics.
---

# Project Todo Softskill

## Overview

Use this softskill to maintain a project-level `PROJECT-TODO.md` based on the user's current request and recent conversation context. It is intended for lightweight project backlog work, triage, review, and planning, not issue-tracker replacement and not code automation. When this softskill is used, the default and only authorized file edit is the resolved `PROJECT-TODO.md`. Merely invoking this softskill does not authorize executing backlog tasks or making code or repository changes outside the todo file.

The softskill should help with:
- adding new todo items from recently discussed topics
- updating priority or wording of existing items
- removing obsolete or completed items when explicitly requested
- reviewing current todo quality and gaps
- turning a topic into an implementation plan before code work starts

## When To Use

- The user explicitly mentions this softskill.
- The user asks to put discussed topics into a todo list.
- The user asks for backlog grooming, task triage, or a project-level implementation plan.
- The user wants recently discussed decisions captured in `PROJECT-TODO.md`.
- The user wants to review, add, update, close, remove, or reorganize todo items without asking for implementation of the underlying work.

## When Not To Use

- Do not use this softskill for normal code edits unrelated to backlog management.
- Do not use this softskill to replace detailed implementation in source files.
- Do not use this softskill to silently invent large new workstreams without grounding them in the current request or recent conversation.
- Do not use this softskill in the same operation as source-code, documentation, configuration, or other non-`PROJECT-TODO.md` file edits.
- Do not treat a reference to a todo item, priority, or backlog topic as permission to execute that task unless the user explicitly asks for implementation.

## Execution Boundary

- Default interpretation: maintain `PROJECT-TODO.md` only.
- Invoking this softskill by name does not by itself authorize implementation of any task listed in `PROJECT-TODO.md`.
- If the user explicitly asks to execute, implement, or carry out a task from `PROJECT-TODO.md`, treat that as a separate implementation request, not as implicit todo-maintenance scope.
- If the request is ambiguous about whether the user wants:
  - to update `PROJECT-TODO.md`, or
  - to execute a task referenced from `PROJECT-TODO.md`
  then ask a concise clarification question before changing anything.
- When in doubt, prefer asking instead of assuming execution intent.

## Source Of Truth

- Primary file: `PROJECT-TODO.md` in the active project root, not automatically in the repository root.
- Allowed edit scope: only the resolved `PROJECT-TODO.md`. If it does not exist yet, create only that file.
- Context sources, in order:
  1. the current user request
  2. the most recent conversation relevant to the topic
  3. the current contents of the resolved `PROJECT-TODO.md`

If `PROJECT-TODO.md` does not exist, first resolve the correct project root and then create it there with the standard structure below.

## Project Root Resolution

Resolve the target project root in this order:

1. If the user explicitly names a project path or subproject, use that.
2. Search for an existing `PROJECT-TODO.md` near the active working area and prefer the nearest matching file.
3. If no todo file exists yet, search for common project markers near the active working area, for example:
   - `*.csproj`
   - `*.sln`
   - `Directory.Build.props`
   - `package.json`
   - `pnpm-workspace.yaml`
   - `deno.json`
   - `deno.jsonc`
   - `pyproject.toml`
   - `setup.py`
   - `requirements.txt`
   - `Pipfile`
   - `uv.lock`
   - `Cargo.toml`
   - `go.mod`
   - `pom.xml`
   - `build.gradle`
   - `settings.gradle`
   - `build.gradle.kts`
   - `settings.gradle.kts`
   - `build.sbt`
   - `composer.json`
   - `Makefile`
   - `README.md` only as a weak fallback marker when no stronger project marker exists
4. If multiple project roots are plausible, choose the one most closely related to the current request and state the assumption briefly.
5. Use the repository root only when it is clearly the active project root or no better project boundary exists.
6. If no clear file marker exists, prefer the nearest folder that looks like a real source root, for example one containing:
   - `src/`
   - `app/`
   - `cmd/`
   - `server/`
   - `services/`
   - `lib/`

Rules:
- Do not assume `.csproj`.
- Do not assume every git repository is one project.
- In a monorepo, prefer the specific subproject over the repo root.
- Search before creating.
- Ignore obvious non-project or generated folders when resolving roots, for example:
  - `.git`
  - `.github`
  - `.vscode`
  - `node_modules`
  - `.venv`
  - `venv`
  - `dist`
  - `build`
  - `target`
  - `bin`
  - `obj`
  - `.next`
  - `.nuxt`
  - `.gradle`
  - `coverage`

## Priority Model

Use exactly these priorities unless the user asks for a different scheme:

- `[P0] Blocker`
- `[P1] Critical`
- `[P2] High`
- `[P3] Normal`
- `[P4] Low`
- `[P5] Backlog / Nice-to-have`
- `[P6] Pixelperfect / optional polish`

Priority guidance:
- `P0`: blocks release, deploy, or core usage
- `P1`: serious risk or security/reliability issue
- `P2`: important product or infrastructure work
- `P3`: normal planned work
- `P4`: low urgency cleanup
- `P5`: useful later, not currently important
- `P6`: cosmetic or polish work that may be skipped

### Recommended Priority Defaults

Use these defaults to avoid over-prioritizing work:

- `P0`:
  - production outage blockers
  - release blockers
  - broken core login or broken core app usage
- `P1`:
  - confirmed security issues
  - externally exposed admin/debug surfaces
  - severe data-loss or integrity risks
- `P2`:
  - important hardening work
  - abuse protection
  - account security improvements
  - core infrastructure work that materially reduces operational risk
  - product bugs that directly impair the usability of core functions
  - core workflow defects that make a primary feature confusing, unreliable, or hard to complete
  - product work that is directly needed for the next planned release step
- `P3`:
  - standard feature completion
  - onboarding completion
  - external provider completion that the app does not strictly need to function
  - documentation-aligned follow-up work
  - normal refactors and product shaping
  - normal non-critical bugs that are undesirable but do not materially impair core function completion
  - secondary usability issues that are visible but not seriously blocking
- `P4`:
  - defensive compatibility improvements
  - minor cleanup
  - low-risk hardening gaps without urgent exposure
- `P5`:
  - future product ideas
  - later monetization or plan-shaping work
  - unfinished but non-urgent capabilities
- `P6`:
  - visual tweaks
  - interaction tuning
  - pixel-perfect polish that may reasonably be skipped

Priority caution:
- Do not assign `P2` or higher just because a topic was recently discussed a lot.
- Capability completion is usually `P3` unless it blocks release, security, or core usage.
- If the app already works without the feature, prefer `P3` or `P5` unless there is a stronger reason.

## Standard File Structure

Use this project-level structure unless the file already uses a coherent variant:

```md
# PROJECT TODO

## Priority Legend
- [P0] Blocker
- [P1] Critical
- [P2] High
- [P3] Normal
- [P4] Low
- [P5] Backlog / Nice-to-have
- [P6] Pixelperfect / optional polish

## Open

### [P0] Blocker
#### Security
- Example task

### [P1] Critical
#### Operations
- Example task

### [P2] High
#### Product
- Example task

### [P3] Normal
#### UX
- Example task

### [P4] Low
#### Cleanup
- Example task

### [P5] Backlog / Nice-to-have
#### Ideas
- Example task

### [P6] Pixelperfect / optional polish
#### Visual polish
- Example task

## Review / Questions
- Example review topic

## Closed

- [P1] Security - 2026-03-08: Example completed item
```

### Structure Rules

- Organize open work by priority headings first.
- Inside each priority, group items by short topic headings such as `Security`, `Auth`, `Navigation`, `Product`, or `Legal`.
- Prefer reusing an existing topic heading inside the same priority instead of creating many near-duplicates.
- If a priority section has no items, it may still remain as an empty heading for visibility.
- `Review / Questions` stays outside the priority tree.
- `Closed` is intentionally flatter than `Open`.
- When an item is completed, move it from `Open` to `Closed` and rewrite it as a compact line:
  - `- [P1] Security - 2026-03-08: Hardened Hangfire dashboard access`

## Item Writing Rules

- Write short, actionable items.
- Prefer one-line tasks with clear scope.
- Reference concrete areas when useful, for example page, feature, or file group.
- Do not turn the todo file into a long design document.
- If an item came from recent conversation, phrase it so it remains understandable later without the chat transcript.
- Place each item under the correct priority heading and under the most fitting topic heading.

Good:
- under `### [P2] High` / `#### Security`: `Harden Hangfire dashboard access for reverse-proxy deployments`
- under `### [P3] Normal` / `#### Identity`: `Add Microsoft external login onboarding verification checklist`

Avoid:
- vague items like `Fix some auth things`
- ungrouped mixed-priority bullet lists

## Supported Actions

### Add
- Add new items from the current request or recent conversation.
- Put them in the correct priority section and topic heading.

### Update
- Rewrite unclear items.
- Adjust priority when the conversation makes urgency clearer.
- Merge duplicates if they describe the same work.
- Move items between priority headings when needed.
- Rehome items into a better topic heading when the current grouping is poor.

### Remove
- Remove items only when the user clearly requests removal or the item is obviously obsolete because the work has been completed and already superseded.

### Close
- When work is completed, move the item to `## Closed`.
- Preserve its priority and topic in the closed line itself.
- Prefer the compact style:
  - `- [P2] Product - 2026-03-08: Added initial public products page`

### Review
- Review the todo file for duplication, vague wording, missing priority, and stale entries.
- Suggest a better item set before editing if the request is review-oriented.

### Plan
- For a specific topic, add a concise implementation-plan item or a small checklist under the relevant task.
- Keep plans shallow unless the user asks for depth.

## Workflow

1. Resolve the active project root using the rules above.
2. Read `PROJECT-TODO.md` there if it exists.
3. Identify topic candidates from the user's current request and recent relevant conversation.
4. Decide whether the task is add, update, remove, review, or plan.
5. If the request could also mean "implement a task from the todo", ask the user which intent they mean before editing anything.
6. Choose the right priority heading and topic heading for each affected item.
7. Apply minimal, clean edits to the project-level `PROJECT-TODO.md` and do not edit any other file.
8. Preserve existing useful structure and history where practical.
9. When closing work, move it into the `Closed` section under the matching priority and topic.
10. Return a short summary of:
   - what changed
   - which project root was targeted
   - any priority choices
   - any assumptions

## Guardrails

- Do not flood the todo file with every small thought from a conversation.
- Prefer fewer, clearer items over many tiny fragments.
- Keep completed or removed history short.
- Do not create duplicate `PROJECT-TODO.md` files across neighboring folders unless the project boundaries are clearly different.
- Do not edit any file other than the resolved `PROJECT-TODO.md`; this softskill does not authorize code changes, README updates, config edits, or any other repository modifications.
- Do not silently switch from todo maintenance into task execution just because the todo item describes implementation work.
- Do not keep flat mixed bullet lists when the file is meant to be priority-grouped.
- Do not create one topic heading per single trivial item unless that grouping really helps.
- Do not put completed work into random prose; keep the compact `priority + topic + date + text` closed-line format.
- If the user asks only for suggestions, you may propose items first, but still update the file when the request is clearly action-oriented.
- If priorities are ambiguous, choose the lowest priority that is still defensible.

## Output Contract

When using this softskill, structure the response in this order:

1. Objective confirmation
2. Constraints and assumptions
3. File plan
4. Applied file changes
5. Validation notes and remaining risks

## Typical Invocation Phrases

- `[$project-todo-softskill] add the recent security findings to the todo`
- `use the todo softskill and turn the recent conversation into backlog items`
- `review PROJECT-TODO.md and suggest priority updates`
- `create a small implementation plan in PROJECT-TODO.md for the topic we just discussed`
- `[$project-todo-softskill] update the SEO item wording in PROJECT-TODO.md`
- `[$project-todo-softskill] do the SEO task from PROJECT-TODO.md` -> ambiguous unless the user clearly means implementation; ask whether they want todo maintenance or execution
