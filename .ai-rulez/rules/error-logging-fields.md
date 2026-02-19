---
priority: high
---

# Error Logging Fields

All error logs must include:
- Error object as 2nd argument (for stack capture)
- Operation name
- Relevant correlation IDs (trace_id, request_id, etc.)
- Context about what was attempted
