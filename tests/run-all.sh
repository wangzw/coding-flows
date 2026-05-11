#!/usr/bin/env bash
# Discover and run every tests/test_*.sh. Each test file is self-contained and
# exits 0 only when every assertion passes. Aggregates results at the end.
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$THIS_DIR"

total_pass=0
total_fail=0
failing_files=()

# Run each test_*.sh in isolation (subshell), capture pass/fail counts from
# the printed summary line.
for tf in test_*.sh; do
  [[ -f "$tf" ]] || continue
  output="$(bash "$tf" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$output"
  summary="$(printf '%s\n' "$output" | grep -E "^$tf" | tail -n1)"
  if [[ -z "$summary" ]]; then
    # Test script exited before emitting summary — treat as catastrophic fail.
    printf '!! %s did not emit a summary line (exit %d)\n' "$tf" "$rc"
    total_fail=$((total_fail + 1))
    failing_files+=("$tf")
    continue
  fi
  pass="$(printf '%s' "$summary" | grep -oE '[0-9]+/[0-9]+' | head -n1 | cut -d/ -f1 || echo 0)"
  total_count="$(printf '%s' "$summary" | grep -oE '[0-9]+/[0-9]+' | head -n1 | cut -d/ -f2 || echo 0)"
  fail=$((total_count - pass))
  total_pass=$((total_pass + pass))
  total_fail=$((total_fail + fail))
  if [[ $rc -ne 0 || $fail -gt 0 ]]; then
    failing_files+=("$tf")
  fi
done

echo
echo "=========================================="
if [[ $total_fail -eq 0 ]]; then
  printf 'ALL TESTS PASS  %d/%d\n' "$total_pass" "$((total_pass + total_fail))"
  exit 0
else
  printf 'FAILED %d/%d  (files: %s)\n' "$total_fail" "$((total_pass + total_fail))" "${failing_files[*]}"
  exit 1
fi
