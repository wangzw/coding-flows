# Test assertion helpers. Sourced by every test_*.sh.

# Global counters (set by run-all.sh per test file).
: "${TEST_FILE:=}"
: "${TEST_PASS:=0}"
: "${TEST_FAIL:=0}"

_test_log() {
  printf '%s\n' "$*" >&2
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    return 0
  fi
  TEST_FAIL=$((TEST_FAIL + 1))
  _test_log "  FAIL [$name]"
  _test_log "    expected: $(printf '%q' "$expected")"
  _test_log "    actual:   $(printf '%q' "$actual")"
  return 1
}

assert_exit_code() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    return 0
  fi
  TEST_FAIL=$((TEST_FAIL + 1))
  _test_log "  FAIL [$name] expected exit=$expected, got exit=$actual"
  return 1
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    return 0
  fi
  TEST_FAIL=$((TEST_FAIL + 1))
  _test_log "  FAIL [$name]"
  _test_log "    expected to contain: $(printf '%q' "$needle")"
  _test_log "    actual: $(printf '%q' "$haystack")"
  return 1
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    return 0
  fi
  TEST_FAIL=$((TEST_FAIL + 1))
  _test_log "  FAIL [$name]"
  _test_log "    expected NOT to contain: $(printf '%q' "$needle")"
  _test_log "    actual: $(printf '%q' "$haystack")"
  return 1
}

test_summary() {
  local total=$((TEST_PASS + TEST_FAIL))
  if [[ $TEST_FAIL -eq 0 ]]; then
    printf '%-50s  %d/%d OK\n' "$TEST_FILE" "$TEST_PASS" "$total"
    return 0
  else
    printf '%-50s  %d/%d FAIL (%d failed)\n' "$TEST_FILE" "$TEST_PASS" "$total" "$TEST_FAIL"
    return 1
  fi
}
