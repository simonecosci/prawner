#!/usr/bin/env bash
#
# tests/run.sh - dependency-free tests for the pure functions of
#                bin/wp-media-clean.sh
#
# These cover the string and set logic only: no WordPress, no database, no
# filesystem under /var/www. Run with: ./tests/run.sh
#
# The restore path cannot be tested this way - it needs real temp trees and
# stubs for chown, stat and wp_run, and those stubs would leak into every
# assertion here - so it has its own runner: ./tests/restore.sh. Run both.
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

# ---------------------------------------------------------------- filenames

assert_eq "thumb: plain"        "photo|800x600|jpg"      "$(parse_thumb_size 'photo-800x600.jpg')"
assert_eq "thumb: dashed base"  "my-holiday|1024x768|png" "$(parse_thumb_size 'my-holiday-1024x768.png')"
assert_eq "thumb: uppercase ext" "photo|150x150|JPEG"    "$(parse_thumb_size 'photo-150x150.JPEG')"
assert_fails "thumb: original is not a thumb"   parse_thumb_size 'photo.jpg'
assert_fails "thumb: numeric suffix is not one" parse_thumb_size 'photo-2.jpg'
assert_fails "thumb: size in the middle"        parse_thumb_size 'photo-800x600-detail.jpg'
assert_fails "thumb: no base before the size"   parse_thumb_size '1024x768.jpg'

assert_eq "variant: scaled"    "photo.jpg"        "$(canonical_original 'photo-scaled.jpg')"
assert_eq "variant: rotated"   "photo.png"        "$(canonical_original 'photo-rotated.png')"
assert_eq "variant: edited"    "photo.jpg"        "$(canonical_original 'photo-e1699999999.jpg')"
assert_eq "variant: plain"     "photo.jpg"        "$(canonical_original 'photo.jpg')"
assert_eq "variant: short -eN is not an edit" "phone-e5.jpg" "$(canonical_original 'phone-e5.jpg')"

assert_eq "encode: space"      "my%20photo.jpg"   "$(urlencode_name 'my photo.jpg')"
assert_eq "encode: safe chars" "foto_1-2.jpg"     "$(urlencode_name 'foto_1-2.jpg')"
assert_eq "encode: utf8"       "citt%C3%A0.jpg"   "$(urlencode_name 'città.jpg')"

# ---------------------------------------------------------------- tokens

assert_eq "id: wp-image class" "42" \
  "$(printf '<img class="x wp-image-42" src="/u/p.jpg">' | extract_id_tokens)"
assert_eq "id: block attribute" "99" \
  "$(printf '<!-- wp:image {"id":99,"sizeSlug":"large"} -->' | extract_id_tokens)"
assert_eq "id: escaped block attribute" "77" \
  "$(printf '&quot;id&quot;:77' | extract_id_tokens)"
assert_eq "id: serialized array" "0
45
1
78" "$(printf 'a:2:{i:0;i:45;i:1;i:78;}' | extract_id_tokens)"
assert_eq "id: serialized numeric string" "123" \
  "$(printf 's:3:"123"' | extract_id_tokens)"
# A bare number in prose must not become an ID: that is what would make the
# ID set swallow the whole library and report nothing.
assert_eq "id: bare number in prose is ignored" "" \
  "$(printf 'published in 2024 with 15 photos' | extract_id_tokens)"

assert_eq "list: comma separated" "12
45
78" "$(printf '12,45,78\n' | expand_id_list)"
assert_eq "list: single value" "123" "$(printf '123\n' | expand_id_list)"
assert_eq "list: non numeric ignored" "" "$(printf 'abc\n1.5\n\n' | expand_id_list)"

# name_is_used reads $WORK/used-names.txt, so the test provides one.
WORK=$(mktemp -d)
printf 'photo.jpg\nmy%%20holiday.jpg\n' > "$WORK/used-names.txt"
assert_eq "used: plain hit"    "yes" "$(name_is_used 'photo.jpg' && echo yes)"
assert_eq "used: miss"         ""    "$(name_is_used 'other.jpg' && echo yes)"
# The reference in the content is percent-encoded while the upload on disk is
# not: without checking the encoded form too, this file looks unused.
assert_eq "used: encoded hit"  "yes" "$(name_is_used 'my holiday.jpg' && echo yes)"
rm -rf "$WORK"; unset WORK

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
