#!/usr/bin/env bash
#
# mayhem/test.sh — run mayhem/oracle.mpc on MP-SPDZ's own emulator (built by mayhem/build.sh) and check values.
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

# Oracle: mayhem/oracle.mpc is compiled by upstream's compile.py (to bytecode + schedule) and executed by
# upstream's emulate.x (bytecode parser, ring arithmetic, comparison/sort/fixed-point libraries). Each
# printed value is compared to its known answer, so a patch that skips or breaks the parser or the
# arithmetic fails here.
T="$SRC/mayhem/build-test"
[ -x "$T/emulate.x" ] && [ -s "$T/Programs/Schedules/mayhem_oracle.sch" ] || { echo "oracle build missing (build.sh)" >&2; emit_ctrf "mp-spdz-oracle" 0 1 0; exit 1; }
cd "$T"
out=$(timeout 300 ./emulate.x mayhem_oracle 2>&1); rc=$?
echo "$out"

passed=0; failed=0
[ "$rc" -eq 0 ] || failed=$((failed + 1))
while IFS='=' read -r key want; do
  got=$(printf '%s\n' "$out" | sed -n "s/^$key=//p" | head -n 1)
  if [ "$got" = "$want" ]; then passed=$((passed + 1)); else echo "FAIL $key: got '$got' want '$want'" >&2; failed=$((failed + 1)); fi
done <<'EXPECTED'
add=12
mul=35
sub=-2
lt=1
eq=0
fix=3.375
sorted=[1, 3, 5, 8, 9]
loop=45
dot=18
pow=1024
bit=1
EXPECTED
emit_ctrf "mp-spdz-oracle" "$passed" "$failed" 0
