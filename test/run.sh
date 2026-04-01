#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

JANET="../zig-out/bin/janet-repl"
export LD_LIBRARY_PATH="../zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export JANET_PATH="../zig-out/lib/janet"

# Find native libs in nix store
for lib in libxkbcommon.so.0 libwayland-client.so.0; do
  nix_lib=$(find /nix/store -maxdepth 3 -name "$lib" 2>/dev/null | head -1)
  if [[ -n "$nix_lib" ]]; then
    export LD_LIBRARY_PATH="$(dirname "$nix_lib"):$LD_LIBRARY_PATH"
  fi
done

if [[ ! -x "$JANET" ]]; then
  echo "error: no janet at $JANET — run 'zig build repl-deps' first"
  exit 1
fi

failed=0
passed=0

for test in ./*.janet; do
  name=$(basename "$test" .janet)
  [[ "$name" == "helper" ]] && continue

  printf "%-20s " "$name"
  if output=$("$JANET" "$test" 2>&1); then
    echo "$output"
    ((passed++)) || true
  else
    echo "FAILED"
    echo "$output" | sed 's/^/  /'
    ((failed++)) || true
  fi
done

echo ""
echo "suites: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
