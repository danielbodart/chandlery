#!/bin/sh
# Valheim. The adapter tests run against a fake server carrying the real
# scripts, so they need no SteamCMD; the image tests need the built image and
# say so plainly when it is absent.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

FAKE=chandlery/test-fake-valheim:test
IMAGE=chandlery/valheim:test
CONTAINER=chandlery-valheim-test-$$
PASSWORD=chandlery

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

run_fake() {
    cleanup
    docker run -d --name "$CONTAINER" -e VALHEIM_PASSWORD="$PASSWORD" "$@" "$FAKE" >/dev/null
}

echo "valheim adapter"

it "refuses to start without a password, and says so"
# Valheim itself exits during startup with nothing useful in the log.
out=$(docker run --rm "$FAKE" 2>&1 || true)
assert_contains "$out" "VALHEIM_PASSWORD is not set" \
    && refute_contains "$out" "fake-valheim: listening" && pass

it "refuses a password Valheim would reject as too short"
out=$(docker run --rm -e VALHEIM_PASSWORD=abc "$FAKE" 2>&1 || true)
assert_contains "$out" "at least 5 characters" && pass

it "refuses a password hidden inside the world name"
out=$(docker run --rm -e VALHEIM_PASSWORD=secret -e VALHEIM_WORLD=mysecretworld "$FAKE" 2>&1 || true)
assert_contains "$out" "cannot appear inside the world name" && pass

it "keeps the world on /data, where a container recreate cannot lose it"
run_fake
if wait_for_log "$CONTAINER" "fake-valheim: args"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-valheim: args //p')
    assert_contains "$args" "-savedir /data" && pass
fi

it "passes the configured name, world and port through to the server"
run_fake -e VALHEIM_NAME=Harbour -e VALHEIM_WORLD=Longship -e VALHEIM_PORT=2466
if wait_for_log "$CONTAINER" "fake-valheim: args"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-valheim: args //p')
    assert_contains "$args" "-name Harbour" \
        && assert_contains "$args" "-world Longship" \
        && assert_contains "$args" "-port 2466" && pass
fi

it "forwards extra arguments for anything this adapter does not model"
run_fake -e VALHEIM_EXTRA_ARGS="-crossplay -preset casual"
if wait_for_log "$CONTAINER" "fake-valheim: args"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-valheim: args //p')
    assert_contains "$args" "-crossplay -preset casual" && pass
fi

it "stops with SIGINT, which is the signal Valheim saves on"
run_fake
if wait_for_log "$CONTAINER" "fake-valheim: listening"; then
    docker stop --timeout 30 "$CONTAINER" >/dev/null
    logs=$(docker logs "$CONTAINER" 2>&1)
    code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
    # The fake ignores SIGTERM, so a wrong signal shows up as a killed container.
    assert_contains "$logs" "fake-valheim: world saved" \
        && refute_contains "$logs" "ignoring SIGTERM" \
        && assert_equals "0" "$code" "137 would mean it had to be killed" && pass
fi

it "reports healthy when the server answers an A2S query"
run_fake
if wait_for_log "$CONTAINER" "fake-valheim: listening"; then
    if out=$(docker exec "$CONTAINER" /usr/local/lib/chandlery/health 2>&1); then
        # The fake challenges the first query, as a modern Steam server does.
        assert_contains "$out" "players=0/10" && pass
    else
        fail "health probe failed against a responding server: $out"
    fi
fi

it "reports unhealthy when nothing is listening"
if docker exec "$CONTAINER" env CHANDLERY_HEALTH_PORT=2499 \
        /usr/local/lib/chandlery/health >/dev/null 2>&1; then
    fail "health probe passed against a dead port"
else
    pass
fi

it "queries the game port plus one, as Valheim requires"
run_fake -e VALHEIM_PORT=2466
if wait_for_log "$CONTAINER" "fake-valheim: listening on udp/2466 (query udp/2467)"; then
    if docker exec "$CONTAINER" /usr/local/lib/chandlery/health >/dev/null 2>&1; then pass; else
        fail "health probe did not follow VALHEIM_PORT to the query port"
    fi
fi

echo
echo "valheim image"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "  skipped: $IMAGE is not built (run: make valheim)"
    summary "valheim"
    return 0 2>/dev/null || exit $?
fi

inspect() { docker run --rm --entrypoint /bin/sh "$IMAGE" -c "$1"; }

it "bakes the server in, so the image needs no download to run"
assert_equals "yes" "$(inspect '[ -x /opt/valheim/valheim_server.x86_64 ] && echo yes')" && pass

it "labels the image with the build id in its tag"
assert_equals "${VALHEIM_BUILD_ID:?set VALHEIM_BUILD_ID}" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" && pass

it "ships the A2S probe its health check calls"
assert_equals "yes" "$(inspect '[ -x /usr/local/bin/chandlery-a2s ] && echo yes')" && pass

it "leaves no SteamCMD download scratch in the image"
assert_equals "" "$(inspect 'ls -d /opt/valheim/steamapps/downloading /opt/valheim/steamapps/temp 2>/dev/null')" && pass

it "runs the server as the non-root chandlery user"
assert_equals "chandlery" "$(docker inspect -f '{{.Config.User}}' "$IMAGE")" && pass

summary "valheim"
