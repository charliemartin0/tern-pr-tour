#!/usr/bin/env bash
# End-to-end: drives the real `tour` block in a private Tern window (control
# endpoint, private daemon) with fake `gh` and `omp` binaries from test/fixtures/bin. Every
# run uses a private daemon, state, config and cache dir; nothing of the user's
# Tern setup is touched.
#   1. omp-ok:   tour renders as one scrolling page (first step title + "model: @smol", every step card, Not toured at the end), cache file written, omp called once.
#   2. restart:  same cache -> header says "cached", omp NOT called again.
#   3. regen:    `r` key calls omp again (cache refreshed).
#   4. omp-fail: error line "omp failed: model not found" and the plain diff by file.
#   5. omp / 6. gh path that cannot be spawned: an error line, not a stuck spinner.
#   7. timeout / 8. invalid JSON: error + plain diff, no cache.
#   9. unsigned / 10. no access / 11. malformed gh JSON: safe error, no model or spinner.
#   12. tools discovered in omp: refuse generation, render plain diff, no cache.
# Usage: bash test/e2e.sh        (needs tern and jq)
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fx="$root/test/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-tour-e2e.XXXXXX")
sha=$(jq -r .headRefOid "$fx/pr_view.json")
first_title=$(jq -r '.steps[0].title' "$fx/model_ok.json")
cache_file="acme_widgets__7__${sha}.json"
daemon_pid=""; serve_pid=""; sock=""

stop_stack() {
	if [ -n "$serve_pid" ] && kill -0 "$serve_pid" 2>/dev/null; then
		tern ctl --control "$sock" quit >/dev/null 2>&1
		for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$serve_pid" 2>/dev/null || break; sleep 0.3; done
		kill -0 "$serve_pid" 2>/dev/null && kill "$serve_pid" 2>/dev/null
		wait "$serve_pid" 2>/dev/null
	fi
	if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
		kill "$daemon_pid" 2>/dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$daemon_pid" 2>/dev/null || break; sleep 0.3; done
		kill -0 "$daemon_pid" 2>/dev/null && kill -9 "$daemon_pid" 2>/dev/null
		wait "$daemon_pid" 2>/dev/null
	fi
	serve_pid=""; daemon_pid=""
}
cleanup() { stop_stack; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
	echo "FAIL: $*"
	[ -f "$tmp/log" ] && { echo "--- tern log ---"; cat "$tmp/log"; }
	[ -f "$tmp/a11y.json" ] && { echo "--- a11y ---"; cat "$tmp/a11y.json"; }
	exit 1
}

# Private plugin dir: only pr-tour, linked to this checkout.
mkdir -p "$tmp/config/tern/plugins" "$tmp/config/tern/plugin-data/pr-tour" "$tmp/state" "$tmp/logs"
printf '%s' "$root" >"$tmp/config/tern/plugins/pr-tour.path"

# start_stack <omp-binary-name | absolute path> <cache-dir> [gh path]
start_stack() {
	local omp="$1" cache="$2" gh="${3:-$fx/bin/gh}"
	case "$omp" in /*) ;; *) omp="$fx/bin/$omp" ;; esac
	jq -n --arg gh "$gh" --arg omp "$omp" --argjson timeout "${OMP_TIMEOUT_S:-90}" \
		'{gh_path: $gh, omp_path: $omp, timeout_s: $timeout}' \
		>"$tmp/config/tern/plugin-data/pr-tour/config.json"
	sock="$tmp/ctl.sock"; rm -f "$sock"
	export TERN_CONFIG_DIR="$tmp/config/tern" TERN_DAEMON_SOCKET="$tmp/daemon.sock" \
		XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
		XDG_CACHE_HOME="$cache" STENCIL_LOG_DIR="$tmp/logs" OMP_CALLS="$tmp/omp.calls"
	rm -f "$TERN_DAEMON_SOCKET"
	tern daemon --socket "$TERN_DAEMON_SOCKET" >>"$tmp/log" 2>&1 &
	daemon_pid=$!
	for _ in $(seq 1 20); do [ -S "$TERN_DAEMON_SOCKET" ] && break; sleep 0.3; done
	[ -S "$TERN_DAEMON_SOCKET" ] || fail "private Tern daemon did not start"
	# `tern serve` loads only fixture plugins, so a real (control-endpoint) window is needed.
	(cd "$root" && PR_TOUR_AUTOOPEN="acme/widgets 7" exec tern --control "$sock" .) >>"$tmp/log" 2>&1 &
	serve_pid=$!
}

# wait_for <substring> [seconds]: polls the a11y tree until a string contains it.
wait_for() {
	local want="$1" secs="${2:-30}" n
	for _ in $(seq 1 $((secs * 2))); do
		kill -0 "$serve_pid" 2>/dev/null || fail "tern window exited early"
		if tern ctl --control "$sock" a11y >"$tmp/a11y.json" 2>/dev/null; then
			n=$(jq --arg s "$want" '[.. | strings | select(contains($s))] | length' "$tmp/a11y.json" 2>/dev/null)
			[ "${n:-0}" -ge 1 ] && return 0
		fi
		sleep 0.5
	done
	return 1
}
has() { jq -e --arg s "$1" '[.. | strings | select(contains($s))] | length > 0' "$tmp/a11y.json" >/dev/null 2>&1; }
calls() { if [ -f "$tmp/omp.calls" ]; then wc -l <"$tmp/omp.calls" | tr -d ' '; else echo 0; fi; }

# Search visible content at incremental offsets rather than assuming a window size.
find_scrolled() {
	local want="$1" y
	for y in $(seq 0 200 10000); do
		tern ctl --control "$sock" a11y set-scroll-offset .sf-main "0,$y" >/dev/null 2>&1 || return 1
		if wait_for "$want" 1; then return 0; fi
	done
	return 1
}

assert_no_spinner() {
	has "Generating tour" && fail "generation spinner remains after error"
	has "Fetching" && fail "fetch spinner remains after error"
}

# Override inherited fixture modes as well as all runtime storage locations.
export OMP_FIXTURE_MODE=ok GH_FIXTURE_MODE=ok OMP_TIMEOUT_S=90 OMP_HAS_TOOLS=0

# Set PR_TOUR_E2E_TOOLS_ONLY=1 to reproduce the tool-refusal regression alone.
if [ "${PR_TOUR_E2E_TOOLS_ONLY:-0}" != "1" ]; then
# --- 1. fresh run with a working model ---
cache1="$tmp/cache1"
start_stack omp-ok "$cache1"
wait_for "$first_title" || fail "tour never rendered step 1 title '$first_title'"
wait_for "model: @smol" 5 || fail "header lacks 'model: @smol'"
[ -f "$cache1/tern-pr-tour/$cache_file" ] || fail "cache file $cache_file missing: $(ls "$cache1/tern-pr-tour" 2>&1)"
[ "$(calls)" = "1" ] || fail "omp calls after fresh run: $(calls), want 1"
# The page is one scroll: the Not toured section sits at the bottom, and the a11y
# tree only holds what is on screen, so scroll down first.
scroll_to_end() {
	tern ctl --control "$sock" a11y set-scroll-offset .sf-main 0,100000 >/dev/null 2>&1
	sleep 1
	tern ctl --control "$sock" a11y >"$tmp/a11y.json" 2>/dev/null
}
scroll_to_end
has "Not toured" || fail "no 'Not toured' section"
# Single page: after scrolling down, the last step's card is on the same page (the outline at the top is off screen by then).
last_title="4. $(jq -r '.steps[3].title' "$fx/model_ok.json")"
[ "$(jq --arg s "$last_title" '[.. | strings | select(. == $s)] | length' "$tmp/a11y.json")" -ge 1 ] || fail "last step card missing from the single page"
has "yarn.lock" || fail "yarn.lock not listed as not toured"
echo "ok 1: tour rendered, cache written, omp called once"
stop_stack

# --- 2. restart with the same cache: no model call ---
start_stack omp-ok "$cache1"
wait_for "$first_title" || fail "cached tour never rendered"
wait_for "cached" 5 || fail "header lacks 'cached'"
has "model: @smol" && fail "cached run still claims a model run"
[ "$(calls)" = "1" ] || fail "omp calls after cached run: $(calls), want 1"
echo "ok 2: cached tour rendered without calling omp"

# --- 3. regenerate with `r` ---
tern ctl --control "$sock" key r >/dev/null 2>&1 || fail "could not send key r"
for _ in $(seq 1 30); do [ "$(calls)" = "2" ] && break; sleep 0.5; done
[ "$(calls)" = "2" ] || fail "omp calls after regenerate: $(calls), want 2"
wait_for "model: @smol" 10 || fail "header lacks 'model: @smol' after regenerate"
echo "ok 3: r regenerated the tour"
stop_stack

# --- 4. failing model: error + plain diff ---
rm -f "$tmp/omp.calls"
cache2="$tmp/cache2"
start_stack omp-fail "$cache2"
wait_for "omp failed: model not found" || fail "error line missing"
# Scroll each file into view: the real window's a11y tree excludes offscreen rows.
for p in README.md config.luau; do find_scrolled "$p" || fail "plain diff lacks file $p"; done
has "$first_title" && fail "fallback shows tour titles"
[ ! -f "$cache2/tern-pr-tour/$cache_file" ] || fail "failed run must not write the cache"
[ -z "$(ls "$cache2"/tern-pr-tour 2>/dev/null | grep '^prompt-')" ] || fail "prompt file not cleaned up"
echo "ok 4: failure shows error and plain diff"

stop_stack

# --- 5. omp cannot be spawned: error + plain diff, not a stuck spinner ---
start_stack /nonexistent/omp "$tmp/cache3"
wait_for "omp failed:" || fail "spawn failure of omp left the block stuck"
has "README.md" || fail "plain diff missing after omp spawn failure"
echo "ok 5: missing omp shows an error and the plain diff"
stop_stack

# --- 6. gh cannot be spawned ---
start_stack omp-ok "$tmp/cache4" /nonexistent/gh
wait_for "gh:" || fail "spawn failure of gh left the block stuck"
has "model: @smol" && fail "tour generated without gh"
echo "ok 6: missing gh shows an error"

stop_stack

# --- 7. bounded model timeout ---
rm -f "$tmp/omp.calls"
export OMP_FIXTURE_MODE=timeout OMP_TIMEOUT_S=1
cache5="$tmp/cache5"
start_stack omp-ok "$cache5"
wait_for "tour generation timed out after 1s" 10 || fail "timeout did not surface"
assert_no_spinner
find_scrolled "config.luau" || fail "timeout fallback lacks plain diff"
[ "$(calls)" = "1" ] || fail "timeout must call omp once"
[ ! -f "$cache5/tern-pr-tour/$cache_file" ] || fail "timeout wrote a cache"
echo "ok 7: model timeout shows plain diff without caching"
stop_stack

# --- 8. malformed model output ---
rm -f "$tmp/omp.calls"
export OMP_FIXTURE_MODE=invalid OMP_TIMEOUT_S=90
cache6="$tmp/cache6"
start_stack omp-ok "$cache6"
wait_for "model returned invalid JSON" || fail "invalid model JSON did not surface"
assert_no_spinner
find_scrolled "config.luau" || fail "invalid JSON fallback lacks plain diff"
has "$first_title" && fail "invalid JSON shows tour titles"
[ "$(calls)" = "1" ] || fail "invalid JSON must call omp once"
[ ! -f "$cache6/tern-pr-tour/$cache_file" ] || fail "invalid JSON wrote a cache"
echo "ok 8: invalid model JSON shows plain diff without caching"
stop_stack

# --- 9–11. gh authentication, access and metadata errors ---
export OMP_FIXTURE_MODE=ok
scenario=9
for mode in unsigned no-access malformed; do
	rm -f "$tmp/omp.calls"
	export GH_FIXTURE_MODE="$mode"
	case "$mode" in
		unsigned) error="gh: not logged into any GitHub hosts" ;;
		no-access) error="gh: Could not resolve to a PullRequest" ;;
		malformed) error="gh: could not read PR details" ;;
	esac
	cache="$tmp/cache-$mode"
	start_stack omp-ok "$cache"
	wait_for "$error" || fail "$mode gh error did not surface"
	[ "$(calls)" = "0" ] || fail "$mode gh error invoked omp"
	has "model: @smol" && fail "$mode gh error shows a model run"
	has "$first_title" && fail "$mode gh error shows tour titles"
	assert_no_spinner
	[ ! -f "$cache/tern-pr-tour/$cache_file" ] || fail "$mode gh error wrote a cache"
	echo "ok $scenario: gh $mode shows a safe error without a model call"
	stop_stack
	scenario=$((scenario + 1))
done
fi

# --- 12. discovered tools must prevent sending PR content to the model ---
rm -f "$tmp/omp.calls"
export GH_FIXTURE_MODE=ok OMP_HAS_TOOLS=1
cache="$tmp/cache-tools"
start_stack omp-ok "$cache"
wait_for "omp exposes tools; refusing to send PR content" 10 || fail "tool-bearing omp was not refused"
assert_no_spinner
[ "$(calls)" = "0" ] || fail "tool-bearing omp received a generation call"
find_scrolled "config.luau" || fail "tool refusal lacks plain diff fallback"
[ ! -f "$cache/tern-pr-tour/$cache_file" ] || fail "tool-bearing omp wrote a cache"
echo "ok 12: discovered tools refuse model generation"
stop_stack

if [ "${PR_TOUR_E2E_TOOLS_ONLY:-0}" = "1" ]; then
	echo "PASS: pr-tour e2e (tool-refusal scenario)"
else
	echo "PASS: pr-tour e2e (12 scenarios)"
fi
