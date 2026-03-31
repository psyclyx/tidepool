#!/usr/bin/env bash
set -euo pipefail

BINARY="./zig-out/bin/tidepool"
TIMEOUT="${1:-30}"

if [[ ! -x "$BINARY" ]]; then
  echo "error: no binary at $BINARY — run zig build first"
  exit 1
fi

echo ":: stopping tidepool.service"
systemctl --user stop tidepool.service

echo ":: starting dev tidepool (${TIMEOUT}s timeout)"
timeout "$TIMEOUT" "$BINARY" -c config/init.janet || status=$?

# timeout exits 124 on expiry, that's expected
if [[ "${status:-0}" -ne 0 && "${status:-0}" -ne 124 ]]; then
  echo ":: tidepool exited with status $status"
fi

echo ":: restarting tidepool.service"
systemctl --user start tidepool.service
echo ":: done"
