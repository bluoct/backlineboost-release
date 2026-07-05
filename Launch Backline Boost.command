#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
cd "$ROOT_DIR"

echo "Building and launching Backline Boost..."
echo

if ! ./script/build_and_run.sh run; then
  status=$?
  echo
  echo "Backline Boost launcher failed with exit code $status."
  echo "Press Return to close this window."
  read -r _
  exit "$status"
fi

echo
echo "Backline Boost launched. You can close this Terminal window."
