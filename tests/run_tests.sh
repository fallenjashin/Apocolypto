#!/usr/bin/env bash
# Usage: ./tests/run_tests.sh /path/to/godot
set -u
G="${1:-godot}"
cd "$(dirname "$0")/.."
"$G" --headless --path . --import >/dev/null 2>&1
if "$G" --headless --path . --check-only -s scripts/game.gd 2>&1 | grep -q "Parse Error"; then
  "$G" --headless --path . --check-only -s scripts/game.gd 2>&1 | grep -A2 "Parse Error"; echo "SOME TESTS FAILED (script error)"; exit 1
fi
echo "== selftest =="
timeout 90 "$G" --headless --path . -- --selftest 2>&1 | grep -E "PASS|FAIL|SELFTEST|^[A-Z]"
s=${PIPESTATUS[0]}
echo "== network test (host + client processes) =="
timeout 90 "$G" --headless --path . -- --autotest-host > /tmp/rooftop_host.log 2>&1 &
hp=$!
sleep 2
timeout 90 "$G" --headless --path . -- --autotest-join 2>&1 | grep -E "^\[join\]|AUTOTEST|FAIL"
j=${PIPESTATUS[0]}
wait $hp; h=$?
grep -E "^\[host\]|AUTOTEST|FAIL" /tmp/rooftop_host.log
if [ $s -eq 0 ] && [ $j -eq 0 ] && [ $h -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
