#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
cd "$ROOT_DIR"

echo "Building and launching Backline Boost..."
echo

# `exit_code`, not `status`: zsh's `status` is a read-only alias of `$?`,
# and assigning to it aborts the script under `set -e`.
exit_code=0
./script/build_and_run.sh run || exit_code=$?
if (( exit_code != 0 )); then
  echo
  echo "Backline Boost launcher failed with exit code $exit_code."
  echo "Press Return to close this window."
  read -r _
  exit "$exit_code"
fi

echo
echo "Backline Boost launched. You can close this Terminal window."
