---
priority: high
---

# Bug Fix Proof Requirement

Bug fix PRs MUST include proof the bug existed before implementing the fix.

**Primary**: Use Test-First workflow with failing tests:
1. Write test expecting CORRECT behavior
2. Mark with `test.fails()` (Vitest) or standard assertion (BATS) - proves bug exists NOW
3. Commit: `[TDD-RED] [BUG-PROOF] test: description`
4. Implement fix, remove marker
5. Commit: `fix: description`

The `[TDD-RED]` commit in git history proves bug existed.

**Fallback**: Use branch comparison ONLY when fix already implemented:
- Run tests on old commit → FAIL (proves bug existed)
- Run tests on new commit → PASS (proves fix works)
- Document before/after results in PR description
