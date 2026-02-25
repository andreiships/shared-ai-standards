---
priority: high
---

# Test-First Workflow

All implementation phases use mandatory TDD (Red-Green-Refactor).

**Workflow**:
1. Write failing tests first → Commit `[TDD-RED]`
2. Implement until tests pass → Commit implementation
3. Refactor as needed

**Key Rules**:
- Write tests before implementation, not after
- Failing tests must be committed to prove the bug/missing behaviour exists
- Phase 0 (Design) is auto-exempt
