#!/usr/bin/env bash
#
# tests/run.sh - dependency-free tests for the pure functions of
#                bin/wp-media-clean.sh
#
# These cover the string and set logic only: no WordPress, no database, no
# filesystem under /var/www. Run with: ./tests/run.sh
#
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Sourcing must be side effect free: if the script runs main() on source, this
# line hangs or exits and every test below is skipped.
# shellcheck source=../bin/wp-media-clean.sh
source "$TESTS_DIR/../bin/wp-media-clean.sh"

PASS=0
FAIL=0
t_red=$'\033[31m'; t_grn=$'\033[32m'; t_off=$'\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf '%s  ok  %s%s\n' "$t_grn" "$desc" "$t_off"
  else
    FAIL=$((FAIL + 1))
    printf '%sFAIL  %s%s\n' "$t_red" "$desc" "$t_off"
    printf '      expected: %q\n' "$expected"
    printf '      actual:   %q\n' "$actual"
  fi
}

assert_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf '%sFAIL  %s (expected a non-zero exit)%s\n' "$t_red" "$desc" "$t_off"
  else
    PASS=$((PASS + 1))
    printf '%s  ok  %s%s\n' "$t_grn" "$desc" "$t_off"
  fi
}

# ---------------------------------------------------------------- skeleton

assert_eq "sourcing does not run main" "1" "$(type -t main >/dev/null && echo 1)"
assert_eq "defaults: dry run" "0" "$APPLY"
assert_eq "defaults: min age" "30" "$MIN_AGE_DAYS"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
