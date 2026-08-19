#!/bin/sh
# Hytale. The adapter tests run against a fake server carrying the real scripts,
# so they need no downloader token and no 3.3 GB download; the image tests need
# the built image and say so plainly when it is absent. The live authenticated
# fetch is exercised on a real host, not here (PLAN 7.1, 7.4).
set -eu
cd "$(dirname "$0")"
. ./lib.sh

FAKE=chandlery/test-fake-hytale:test
IMAGE=chandlery/hytale:test
CONTAINER=chandlery-hytale-test-$$

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

run_fake() {
    cleanup
    docker run -d --name "$CONTAINER" "$@" "$FAKE" >/dev/null
}

echo "hytale adapter"

it "boots online-unauthenticated when the server tokens are absent, and says how"
# Env tokens are optional: the game authenticates online-unauthenticated and can
# be logged in later with `/auth login` on the console, so a missing token warns
# and boots rather than refusing. Online, so no --auth-mode offline on argv.
run_fake
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    logs=$(docker logs "$CONTAINER" 2>&1)
    args=$(echo "$logs" | sed -n 's/^fake-java: args //p')
    assert_contains "$logs" "/auth login" \
        && refute_contains "$args" "--auth-mode offline" && pass
fi

it "starts in offline mode with no credentials at all"
run_fake -e HYTALE_AUTH_MODE=offline
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    assert_contains "$args" "--auth-mode offline" \
        && assert_contains "$args" "--disable-sentry" \
        && assert_contains "$args" "--assets " \
        && assert_contains "$args" "-jar " && pass
fi

it "needs no downloader token at start — the game is baked"
# prepare must not demand HYTALE_ACCESS_TOKEN: the fetch happened at build.
run_fake -e HYTALE_AUTH_MODE=offline
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    logs=$(docker logs "$CONTAINER" 2>&1)
    refute_contains "$logs" "HYTALE_ACCESS_TOKEN is not set" && pass
fi

it "keeps the server session tokens off the command line"
# The server reads them from the environment; argv is world-readable via ps.
run_fake -e HYTALE_SERVER_SESSION_TOKEN=sess-secret \
         -e HYTALE_SERVER_IDENTITY_TOKEN=id-secret
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    refute_contains "$args" "sess-secret" \
        && refute_contains "$args" "id-secret" \
        && refute_contains "$args" "--auth-mode offline" && pass
fi

it "forwards extra arguments for anything this adapter does not model"
run_fake -e HYTALE_AUTH_MODE=offline -e HYTALE_EXTRA_ARGS="--max-players 40"
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    assert_contains "$args" "--max-players 40" && pass
fi

it "shuts down through the console, and saves, rather than being killed"
run_fake -e HYTALE_AUTH_MODE=offline
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    docker stop --timeout 30 "$CONTAINER" >/dev/null
    logs=$(docker logs "$CONTAINER" 2>&1)
    code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
    assert_contains "$logs" "fake-hytale: console /stop" \
        && assert_contains "$logs" "fake-hytale: saving world" \
        && assert_equals "0" "$code" "137 would mean it had to be killed" && pass
fi

echo
echo "hytale image"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "  skipped: $IMAGE is not built (run: make hytale)"
    summary "hytale"
    return 0 2>/dev/null || exit $?
fi

inspect() { docker run --rm --entrypoint /bin/sh "$IMAGE" -c "$1"; }

it "bakes the server jar and the (unzipped) assets it names, at /opt/hytale"
# Assets are baked as a directory (the server takes --assets as DIR_OR_ZIP) so
# they bucket and dedupe; a baked Assets.zip is the accepted fallback.
assert_equals "yes" "$(inspect '[ -f /opt/hytale/Server/HytaleServer.jar ] &&
                                 { [ -d /opt/hytale/Assets ] || [ -f /opt/hytale/Assets.zip ]; } && echo yes')" && pass

it "records the version in its tag's label and environment"
assert_equals "${HYTALE_VERSION:?set HYTALE_VERSION}" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" \
  && assert_equals "${HYTALE_VERSION}" "$(inspect 'echo "$HYTALE_VERSION"')" && pass

it "ships Java, and needs no runtime fetch machinery"
assert_equals "yes" "$(inspect '[ -x "$JAVA_HOME/bin/java" ] &&
                                 [ ! -e /usr/local/lib/chandlery/fetch ] &&
                                 ! command -v curl >/dev/null 2>&1 &&
                                 ! command -v jq >/dev/null 2>&1 && echo yes')" && pass

it "disables the server's own auto-updater, so the tag stays honest"
assert_equals "1" "$(inspect 'echo "$HYTALE_DISABLE_UPDATES"')" && pass

it "ships no health check (no in-box protocol probe)"
assert_equals "<nil>" "$(docker inspect -f '{{.Config.Healthcheck}}' "$IMAGE")" && pass

it "runs the server as the non-root chandlery user"
assert_equals "chandlery" "$(docker inspect -f '{{.Config.User}}' "$IMAGE")" && pass

summary "hytale"
