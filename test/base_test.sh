#!/bin/sh
# What the skeleton has to get right, proven against a real container:
# a server that ignores SIGTERM still saves and exits 0 on `docker stop`.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

HOOKED=chandlery/test-fake-server:test
NOHOOK=chandlery/test-signal-server:test
CONTAINER=chandlery-base-test-$$

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "base skeleton"

it "stops a SIGTERM-deaf server by its own console, and saves"
cleanup
docker run -d --name "$CONTAINER" "$HOOKED" >/dev/null
if wait_for_log "$CONTAINER" "fake-server: listening"; then
    # 30s is well beyond the fixture's 1s save; if we hit it, stopping is broken.
    docker stop --timeout 30 "$CONTAINER" >/dev/null
    logs=$(docker logs "$CONTAINER" 2>&1)
    code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
    assert_contains "$logs" "fake-server: console said [stop]" \
        && assert_contains "$logs" "fake-server: world saved" \
        && assert_equals "0" "$code" "container exit code" \
        && pass
fi

it "waits for the save instead of killing the server"
# The fixture only prints "world saved" if it got its full second after "stop".
# Docker reports exit 137 when it runs out of patience and sends SIGKILL.
logs=$(docker logs "$CONTAINER" 2>&1)
code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
refute_contains "$logs" "ignoring SIGTERM" \
    && assert_equals "0" "$code" "137 would mean SIGKILL" \
    && pass

it "forwards SIGTERM when the game has no stop hook"
cleanup
docker run -d --name "$CONTAINER" "$NOHOOK" >/dev/null
if wait_for_log "$CONTAINER" "signal-server: listening"; then
    docker stop --timeout 30 "$CONTAINER" >/dev/null
    logs=$(docker logs "$CONTAINER" 2>&1)
    code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
    assert_contains "$logs" "signal-server: saving on SIGTERM" \
        && assert_equals "0" "$code" "container exit code" \
        && pass
fi

it "accepts console commands from docker exec"
cleanup
docker run -d --name "$CONTAINER" "$HOOKED" >/dev/null
if wait_for_log "$CONTAINER" "fake-server: listening"; then
    docker exec "$CONTAINER" chandlery-console say hello there
    sleep 1
    assert_contains "$(docker logs "$CONTAINER" 2>&1)" \
        "fake-server: console said [say hello there]" && pass
fi

it "keeps the console open after a command, rather than closing stdin"
docker exec "$CONTAINER" chandlery-console noop >/dev/null
sleep 1
assert_equals "true" "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" \
    "server died when the writer closed" && pass

it "runs the server as the non-root chandlery user"
# Ask the server, not `docker exec`: exec runs as the container's configured
# user, which tells us nothing about who the server process actually is.
assert_contains "$(docker logs "$CONTAINER" 2>&1)" "fake-server: running as chandlery" && pass

it "drops from root to chandlery, and adopts /data on the way"
cleanup
# A root-owned bind mount is the normal homelab case; the entrypoint should
# take it over rather than leaving the server unable to write its world.
world=$(mktemp -d)
chown 0:0 "$world"
docker run -d --name "$CONTAINER" --user 0 -v "$world:/data" "$HOOKED" >/dev/null
if wait_for_log "$CONTAINER" "fake-server: listening"; then
    owner=$(docker exec "$CONTAINER" stat -c '%U' /data)
    logs=$(docker logs "$CONTAINER" 2>&1)
    assert_contains "$logs" "dropping to chandlery" \
        && assert_contains "$logs" "fake-server: running as chandlery" \
        && assert_equals "chandlery" "$owner" "/data owner" \
        && pass
fi
rm -rf "$world"

summary "base skeleton"
