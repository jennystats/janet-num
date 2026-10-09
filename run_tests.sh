#!/bin/sh
# run_tests.sh - janet-num smoke suite; typed lives outside the repo,
# so seed the default user module path when the env has none.
[ -n "$JANET_PATH" ] || export JANET_PATH="$HOME/.local/lib/janet"
if janet test/smoke-janet-num.janet; then
  echo "RESULT: pass"
else
  echo "RESULT: fail"
  exit 1
fi
