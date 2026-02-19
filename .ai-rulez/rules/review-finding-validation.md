---
priority: high
---

# Review Finding Validation

Before applying review suggestions for CLI commands, verify flags exist in official documentation.
AI reviewers may hallucinate flags based on patterns from other tools (e.g., suggesting --yes
for commands that don't support it).

**Validation workflow**:
1. Check official docs for the suggested flag
2. Test locally with `command --help` if uncertain
3. Use deep research tools for authoritative validation when docs are unclear
4. Document findings in runbooks to prevent recurrence

**Common hallucination**: Suggesting `--yes`, `--pipe`, or `--stdin` flags for commands
that auto-detect piped input.
