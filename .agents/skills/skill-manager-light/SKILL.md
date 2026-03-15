---
name: skill-manager-light
description: Create and update Codex skill files directly from user descriptions using lightweight instructions, checklists, and quality criteria.
---

# SoftSkill Manager

## Overview

Use this skill to create or update skill files directly in `.agents/skills` from a concise user description. It is lightweight and focuses on clear instructions, practical defaults, and fast quality checks.

## When To Use

- You need a new skill scaffold created from requirements.
- You need to revise `SKILL.md` or `agents/openai.yaml` for an existing skill.
- You need lightweight guidance plus direct file edits in one flow.
- You need repeatable checklists for skill quality without heavy automation.

## When Not To Use

- Do not use this skill for unrelated application code changes.
- Do not use this skill when the request is only conceptual brainstorming with no file changes.

## Interaction Contract

Always structure responses in this order:

1. Objective confirmation
2. Constraints and assumptions
3. File plan
4. Applied file changes
5. Validation notes and remaining risks

## Core Workflows

### 1. Create New Skill From Description

- Derive a lowercase hyphen-case skill name.
- Create required files and folders under `.agents/skills/<skill-name>`.
- Write `SKILL.md` with complete frontmatter and actionable instructions.
- Write `agents/openai.yaml` with valid interface values.
- Add reference files only when they materially support the skill.
- When the requested skill is a softskill, default to a generic, reusable design unless the user explicitly wants repo- or stack-specific behavior.

### Softskill Genericity Defaults

When creating or revising a softskill:

- Prefer technology-agnostic wording over stack-specific wording.
- Do not hardcode one specific language, framework, manifest filename, repository, or project layout unless the user explicitly requests it.
- Prefer discovery rules over fixed paths when the softskill may be reused across projects.
- If project-root or file-root detection matters, describe a search order and fallback rules instead of one hardcoded location.
- Keep the softskill portable across different project types and ecosystems when reasonable.
- Only bake in concrete repository paths when the user clearly wants a repo-local skill tied to this codebase.
- If a skill starts repo-specific but the user later asks for generic behavior, prefer generalizing the rules instead of duplicating the skill.

### 2. Update Existing Skill

- Read current files first and preserve valid existing structure.
- Apply minimal, targeted edits tied to the requested behavior.
- Keep naming, invocation wording, and constraints consistent.

### 3. Quality Check

- Ensure `SKILL.md` frontmatter contains only allowed keys and required fields.
- Ensure `description` is clear and free of angle brackets.
- Ensure `openai.yaml` interface values are quoted strings.
- Ensure `short_description` is meaningful and between 25 and 64 characters.
- Remove template placeholders and unresolved markers.
- For softskills, check whether the instructions are more repo-specific than necessary.
- For reusable softskills, prefer explicit discovery heuristics over hardcoded project assumptions.
- If a skill intentionally stays repo-specific, make that scope explicit in the description or workflow.

### 4. Deliverable Summary

- Return changed file paths.
- Summarize key behavior and invocation phrase.
- List any assumptions and suggested follow-up edits.

## Execution Rules

- Create and update files directly when requested.
- Prefer simple, explicit file structures over over-engineered scaffolding.
- Keep outputs deterministic and easy to review.
- When there is a choice, prefer the least-coupled softskill design that still fulfills the user's purpose.

## Outputs

Every engagement should produce reusable artifacts:

- `Skill Brief`
- `File Change Set`
- `Validation Notes`

## References

- `references/softskill_checklists.md`


