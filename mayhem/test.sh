#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Runs every gtest binary build.sh produced and sums gtest's own "[  PASSED  ] N tests." /
# "[  FAILED  ] N tests, listed below:" summary lines. A binary that is missing, or prints neither
# line (e.g. the program was neutered to exit(0)), counts as one failure — nothing is ever skipped.
# A failing binary is retried once: a few of the suites bind localhost sockets and can lose a race.
dir="$SRC/build-tests/tests"
[ -d "$dir" ] || { echo "missing $dir — mayhem/build.sh must build the suite" >&2; emit_ctrf gtest 0 1 0; exit 1; }

run_one() {  # sets P and F for one binary
  local out
  out="$(cd "$dir" && timeout 600 "./$1" 2>&1)" || true
  P="$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)"
  F="$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)"
  printf '%s\n' "$out" | tail -n 3
  P="${P:-0}" ; F="${F:-0}"
  if [ "$P" -eq 0 ] && [ "$F" -eq 0 ]; then F=1; fi
}

passed=0 ; failed=0
bins="async_test cookie_test cookie_test_2 cookie_test_3 endpoint_initialization_test headers_test helpers_test \
http_client_test http_parsing_test http_server_test http_uri_test listener_test log_api_test mailbox_test \
mime_test reactor_test request_size_test rest_server_test router_test stream_test streaming_test \
string_logger_test threadname_test typeid_test view_test"
for b in $bins; do
  echo "== run_$b"
  if [ ! -x "$dir/run_$b" ]; then echo "missing run_$b" >&2; failed=$((failed + 1)); continue; fi
  run_one "run_$b"
  if [ "$F" -gt 0 ]; then echo "== retrying run_$b once" >&2; run_one "run_$b"; fi
  passed=$((passed + P)) ; failed=$((failed + F))
done

emit_ctrf gtest "$passed" "$failed" 0
