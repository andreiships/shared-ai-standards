---
priority: high
---

# Correlation ID Propagation

Always propagate correlation IDs (trace_id, request_id, session_id, etc.) through function calls.
- Create IDs at boundary entry (HTTP route, WebSocket message, queue consumer)
- Pass existing IDs to child operations
- Never generate new trace_id mid-operation (breaks correlation)
