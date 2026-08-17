#!/bin/sh
# Minimal test scaffolding. No framework: these tests drive `docker`, so the
# interesting part is always the docker invocation, not the assertions.
set -eu

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

it() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  %s ... ' "$1"
}

pass() { printf 'ok\n'; }

fail() {
    printf 'FAIL\n'
    printf '    %s\n' "$*" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_equals() {
    if [ "$1" = "$2" ]; then return 0; fi
    fail "expected [$1], got [$2]${3:+ ($3)}"
    return 1
}

assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    fail "expected to find [$2] in:
$(printf '%s' "$1" | sed 's/^/      | /')"
    return 1
}

refute_contains() {
    case "$1" in
        *"$2"*)
            fail "did not expect to find [$2] in:
$(printf '%s' "$1" | sed 's/^/      | /')"
            return 1
            ;;
    esac
    return 0
}

# Poll until the container's logs contain a marker, so tests key off the
# server actually being up rather than a hopeful sleep.
wait_for_log() {
    container="$1"; marker="$2"; timeout="${3:-30}"
    waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if docker logs "$container" 2>&1 | grep -qF "$marker"; then return 0; fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "timed out after ${timeout}s waiting for [$marker]; logs:
$(docker logs "$container" 2>&1 | sed 's/^/      | /')"
    return 1
}

summary() {
    printf '\n%s: %s test(s), %s failure(s)\n' "${1:-tests}" "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}
