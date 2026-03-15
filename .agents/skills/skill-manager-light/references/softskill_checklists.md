# SoftSkill Checklists

## Naming Checklist

- Use lowercase hyphen-case for the skill `name`.
- Keep the name specific to capability and easy to invoke.
- Avoid collisions with existing names under `.agents/skills`.
- Confirm the spoken prompt phrasing maps naturally to the skill name.

## SKILL.md Authoring Checklist

- Frontmatter includes `name` and `description`.
- Frontmatter uses only allowed keys.
- Description states purpose and clear trigger conditions.
- Body sections define behavior, scope boundaries, and outputs.
- No placeholder text remains.

## agents/openai.yaml Checklist

- `display_name` is user-facing and does not contain `$`.
- `short_description` is meaningful and 25-64 characters long.
- `default_prompt` explicitly references `$skill-name` usage.
- Quote all string values and keep keys unquoted.

## Direct Creation Template

Use this template when creating a skill from description:

```markdown
Skill Brief
- Goal: <goal>
- Scope: <in-scope>
- Out of scope: <out-of-scope>

Planned Files
- .agents/skills/<skill-name>/SKILL.md
- .agents/skills/<skill-name>/agents/openai.yaml
- .agents/skills/<skill-name>/references/<optional-file>.md

Validation Notes
- Frontmatter keys validated
- Description validated
- Interface fields validated
- Placeholder scan clean
```


