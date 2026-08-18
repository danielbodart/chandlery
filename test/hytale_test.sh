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

it "refuses to start online without the two server tokens, and says which"
out=$(docker run --rm "$FAKE" 2>&1 || true)
assert_contains "$out" "HYTALE_SERVER_SESSION_TOKEN" \
    && assert_contains "$out" "HYTALE_SERVER_IDENTITY_TOKEN" \
    && refute_contains "$out" "fake-hytale: listening" && pass

it "starts in offline mode with no credentials at all"
run_fake -e HYTALE_AUTH_MODE=offline
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    assert_contains "$args" "--auth-mode offline" \
        && assert_contains "$args" "--disable-sentry" \
        && assert_contains "$args" "--assets " \
        && assert_contains "$args" "-jar " && pass
fi

it "takes the cache fast path, needing no downloader token when already fetched"
# prepare must not demand HYTALE_ACCESS_TOKEN when /cache already has the version.
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

it "carries no game content — it pins the version, not the bytes"
assert_equals "" "$(inspect 'find / -name "*.jar" -not -path "*/cache/*" 2>/dev/null | grep -v /opt/java/ || true')" && pass

it "records the version in its tag's label and environment"
assert_equals "${HYTALE_VERSION:?set HYTALE_VERSION}" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" \
  && assert_equals "${HYTALE_VERSION}" "$(inspect 'echo "$HYTALE_VERSION"')" && pass

it "ships Java and the fetch machinery, not a baked payload"
assert_equals "yes" "$(inspect '[ -x "$JAVA_HOME/bin/java" ] &&
                                 [ -x /usr/local/lib/chandlery/fetch ] &&
                                 [ -x /usr/local/bin/chandlery-cache ] && echo yes')" && pass

it "disables the server's own auto-updater, so the tag stays honest"
assert_equals "1" "$(inspect 'echo "$HYTALE_DISABLE_UPDATES"')" && pass

it "ships no health check (no in-box protocol probe)"
assert_equals "<nil>" "$(docker inspect -f '{{.Config.Healthcheck}}' "$IMAGE")" && pass

it "runs the server as the non-root chandlery user"
assert_equals "chandlery" "$(docker inspect -f '{{.Config.User}}' "$IMAGE")" && pass

summary "hytale"
