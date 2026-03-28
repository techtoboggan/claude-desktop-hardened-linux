#!/bin/bash
# Integration test for the doctor.sh diagnostic script.
# Run: bash tests/test_doctor.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$SCRIPT_DIR/scripts/doctor.sh"
PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2"
    shift 2
    if "$@" 2>/dev/null; then
        if [ "$expected" = "pass" ]; then
            echo "  PASS: $desc"
            ((PASS++))
        else
            echo "  FAIL: $desc (expected failure but passed)"
            ((FAIL++))
        fi
    else
        if [ "$expected" = "fail" ]; then
            echo "  PASS: $desc (correctly failed)"
            ((PASS++))
        else
            echo "  FAIL: $desc (expected pass but failed)"
            ((FAIL++))
        fi
    fi
}

echo "=== Doctor Script Tests ==="
echo

# Test 1: Script exists and is executable
check "doctor.sh exists" "pass" test -x "$DOCTOR"

# Test 2: Script runs without crashing (exit code 1 is expected when tools are missing)
check "doctor.sh runs without crashing" "pass" bash -c "bash '$DOCTOR' >/dev/null 2>&1; [ \$? -le 1 ]"

# Test 3: Output contains expected sections
OUTPUT=$(bash "$DOCTOR" 2>&1 || true)
check "output contains Electron section" "pass" grep -q "Electron" <<< "$OUTPUT"
check "output contains Bubblewrap section" "pass" grep -q "Bubblewrap" <<< "$OUTPUT"
check "output contains Display Server section" "pass" grep -q "Display Server" <<< "$OUTPUT"
check "output contains Node.js section" "pass" grep -q "Node.js" <<< "$OUTPUT"
check "output contains summary line" "pass" grep -q "Summary:" <<< "$OUTPUT"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
