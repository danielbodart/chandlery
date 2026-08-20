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

run_fake() {  # docker options go before the image
    cleanup
    docker run -d --name "$CONTAINER" -e VALHEIM_PASSWORD="$PASSWORD" "$@" "$FAKE" >/dev/null
}

run_cmd() {  # arguments go after the image, the way compose `command:` passes them
    cleanup
    docker run -d --name "$CONTAINER" -e VALHEIM_PASSWORD="$PASSWORD" "$FAKE" "$@" >/dev/null
}

echo "valheim adapter"

it "keeps the world on /data, where a container recreate cannot lose it"
run_fake
if wait_for_log "$CONTAINER" "fake-valheim: args"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-valheim: args //p')
    assert_contains "$args" "-savedir /data" && pass
fi

it "injects the password from the environment, not from the command line"
# The password is a secret, so it comes from VALHEIM_PASSWORD (never asked for on
# the compose command line); the adapter puts it on argv because Valheim has no
# other channel for it.
run_fake
if wait_for_log "$CONTAINER" "fake-valheim: args"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-valheim: args //p')
    assert_contains "$args" "-password $PASSWORD" && pass
fi

it "forwards the container's own arguments (compose command:) to the server"
# `command:` replaces CMD wholesale, so it names the wrapper first (as postgres
# names postgres), then the flags.
run_cmd valheim-server -name Harbour -world Longship -port 2466 -crossplay
if wait_for_log "$CONTAINER" "fake-valheim: args"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-valheim: args //p')
    assert_contains "$args" "-name Harbour" \
        && assert_contains "$args" "-world Longship" \
        && assert_contains "$args" "-port 2466" \
        && assert_contains "$args" "-crossplay" && pass
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

it "reports unhealthy when nothing answers the query"
# Override the probe itself — call the A2S tool at a dead port — rather than
# feeding the hook a fake port. There is no port env to bend: the hook probes the
# fixed container-internal query port (2457), and this proves the tool fails when
# nothing is there.
run_fake
if wait_for_log "$CONTAINER" "fake-valheim: listening"; then
    if docker exec "$CONTAINER" /usr/local/bin/chandlery-a2s -host 127.0.0.1 -port 2499 >/dev/null 2>&1; then
        fail "the A2S probe passed against a dead port"
    else
        pass
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

it "bakes the server it names, executable, at /opt/valheim"
assert_equals "yes" "$(inspect '[ -x /opt/valheim/valheim_server.x86_64 ] && echo yes')" && pass

it "tags the image with the game version, and records the build id and gid"
assert_equals "${VALHEIM_VERSION:?set VALHEIM_VERSION}" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" \
  && assert_equals "${VALHEIM_BUILD_ID:?set VALHEIM_BUILD_ID}" \
    "$(docker inspect -f '{{index .Config.Labels "dev.chandlery.valheim.build-id"}}' "$IMAGE")" \
  && assert_equals "${VALHEIM_MANIFEST_GID:?set VALHEIM_MANIFEST_GID}" \
    "$(inspect 'echo "$VALHEIM_MANIFEST_GID"')" && pass

it "bakes a current steamclient.so and needs no runtime fetch machinery"
# Baked: DepotDownloader/SteamCMD did the fetch at build and do not ride into the
# runtime image; a current steamclient.so is baked beside the server (the depot's
# own is too old for the server's Steam init).
assert_equals "yes" "$(inspect '[ -f /opt/valheim/steamclient.so ] &&
                                 [ ! -e /opt/depotdownloader/DepotDownloader ] &&
                                 [ ! -e /opt/steamcmd/steamcmd.sh ] &&
                                 [ ! -e /usr/local/lib/chandlery/fetch ] &&
                                 ! command -v curl >/dev/null 2>&1 && echo yes')" && pass

it "ships the A2S probe its health check calls"
assert_equals "yes" "$(inspect '[ -x /usr/local/bin/chandlery-a2s ] && echo yes')" && pass

it "runs the server as the non-root chandlery user"
assert_equals "chandlery" "$(docker inspect -f '{{.Config.User}}' "$IMAGE")" && pass

summary "valheim"
