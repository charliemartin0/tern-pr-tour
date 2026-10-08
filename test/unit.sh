#!/usr/bin/env bash
# Unit tests (tour.luau, config.luau) with the Luau CLI. The CLI has no file
# I/O, so the fixtures are passed as arguments.
# Usage: bash test/unit.sh        (LUAU=/path/to/luau to pick the binary)
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fx="$root/test/fixtures"
luau="${LUAU:-$(command -v luau || true)}"
[ -x "${luau:-}" ] || { echo "FAIL: luau CLI not found (set LUAU=/path/to/luau)"; exit 1; }
cd "$root"
exec "$luau" test/test.luau -a "$(cat "$fx/pr.diff")" "$(cat "$fx/model_ok.json")" "$(cat "$fx/model_missing_dup.json")"
