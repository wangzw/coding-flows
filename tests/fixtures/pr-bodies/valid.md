## Summary

Adds rate limiting. Closes #142.

## AC mapping

| AC   | Description                              | Test                              | Code              | Commit  |
|------|------------------------------------------|-----------------------------------|-------------------|---------|
| AC-1 | 429 on >100 rps                          | proxy_test.go:Throttles           | proxy.go:84-110   | a1b2c3d |
| AC-2 | Retry-After header reflects window       | proxy_test.go:RetryAfter          | proxy.go:112-120  | a1b2c3d |
| AC-3 | Bypass for keys with unlimited scope     | proxy_test.go:UnlimitedBypass     | proxy.go:75-83    | e5f6g7h |

## Test plan
- [x] manual smoke
