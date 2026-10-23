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

run_fake() {  # docker options go before the image
    cleanup
    docker run -d --name "$CONTAINER" "$@" "$FAKE" >/dev/null
}

run_cmd() {  # arguments go after the image, the way compose `command:` passes them
    cleanup
    docker run -d --name "$CONTAINER" "$FAKE" "$@" >/dev/null
}

echo "hytale adapter"

it "boots online by default, adding no auth flags to the command line"
# Online is the game's own default and needs no token to boot; the server reads
# any session tokens from its own environment and logs its own auth status. The
# adapter adds nothing about auth to argv.
run_fake
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    assert_contains "$args" "--assets " \
        && assert_contains "$args" "-jar " \
        && refute_contains "$args" "--auth-mode" && pass
fi

it "forwards the container's own arguments (compose command:) to the server"
# --auth-mode offline, --max-players … — any server flag passes straight through,
# no env re-encoding.
# `command:` replaces CMD wholesale, so it names the wrapper first, then flags.
run_cmd hytale-server --auth-mode offline --max-players 40
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    assert_contains "$args" "--auth-mode offline" \
        && assert_contains "$args" "--max-players 40" \
        && assert_contains "$args" "--disable-sentry" && pass
fi

it "needs no downloader token at start — the game is baked"
# prepare must not demand HYTALE_ACCESS_TOKEN: the fetch happened at build.
run_fake
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    logs=$(docker logs "$CONTAINER" 2>&1)
    refute_contains "$logs" "HYTALE_ACCESS_TOKEN is not set" && pass
fi

it "keeps the server session tokens off the command line"
# The server reads them from its own environment; argv is world-readable via ps.
run_fake -e HYTALE_SERVER_SESSION_TOKEN=sess-secret \
         -e HYTALE_SERVER_IDENTITY_TOKEN=id-secret
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    args=$(docker logs "$CONTAINER" 2>&1 | sed -n 's/^fake-java: args //p')
    refute_contains "$args" "sess-secret" \
        && refute_contains "$args" "id-secret" && pass
fi

it "boots unauthenticated, with a warning, when the Treesinger broker is unreachable"
# TREESINGER_URL set but nothing listening: the fetch fails and the server still
# comes up rather than crashing. (A live mint is verified on the host against a
# real broker.)
run_fake -e TREESINGER_URL=http://127.0.0.1:1
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    logs=$(docker logs "$CONTAINER" 2>&1)
    assert_contains "$logs" "could not reach Treesinger" && pass
fi

it "boots unauthenticated, with a warning, when the Treesinger socket is absent"
# TREESINGER_SOCKET is how a native unit reaches the broker (docs/nix.md); the
# same degradation as an unreachable URL.
run_fake -e TREESINGER_SOCKET=/run/treesinger/treesinger.sock
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    logs=$(docker logs "$CONTAINER" 2>&1)
    assert_contains "$logs" "could not reach Treesinger at /run/treesinger/treesinger.sock" && pass
fi

it "mints a session over the Treesinger socket, into the environment and not argv"
# A broker on a unix socket on the host, bound in as the native unit binds
# /run/treesinger: POST /v1/session answers with a session, as Treesinger does.
broker_dir=$(mktemp -d)
chmod 0755 "$broker_dir"
python3 - "$broker_dir/treesinger.sock" <<'PY' &
import http.server, os, socketserver, sys
class Broker(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = b'{"sessionToken":"sess.from.socket","identityToken":"id.from.socket"}'
        self.send_response(200 if self.path == "/v1/session" else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
class Server(socketserver.UnixStreamServer):
    def get_request(self):
        return self.socket.accept()[0], ("unix", 0)
server = Server(sys.argv[1], Broker)
os.chmod(sys.argv[1], 0o777)
server.serve_forever()
PY
broker=$!
waited=0
while [ ! -S "$broker_dir/treesinger.sock" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
run_fake -v "$broker_dir:/run/treesinger" -e TREESINGER_SOCKET=/run/treesinger/treesinger.sock
if wait_for_log "$CONTAINER" "fake-hytale: listening"; then
    logs=$(docker logs "$CONTAINER" 2>&1)
    args=$(printf '%s\n' "$logs" | sed -n 's/^fake-java: args //p')
    assert_contains "$logs" "authenticated via Treesinger (/run/treesinger/treesinger.sock)" \
        && assert_contains "$logs" "fake-java: session sess.from.socket identity id.from.socket" \
        && refute_contains "$args" "from.socket" && pass
fi
kill "$broker" 2>/dev/null || true
rm -rf "$broker_dir"

it "extracts both JWTs from a Treesinger session response, jq-free"
# Mirrors the parse in images/hytale/run (POSIX sed, no jq in the image). JWTs
# are base64url + '.', so a "[^\"]*" field match is safe.
body='{"sessionToken":"aaa.bbb.ccc","identityToken":"xxx.yyy.zzz","expiresAt":"2026-01-07T15:00:00Z"}'
st=$(printf '%s' "$body" | sed -n 's/.*"sessionToken":"\([^"]*\)".*/\1/p')
it_tok=$(printf '%s' "$body" | sed -n 's/.*"identityToken":"\([^"]*\)".*/\1/p')
assert_equals "aaa.bbb.ccc" "$st" && assert_equals "xxx.yyy.zzz" "$it_tok" && pass

it "shuts down through the console, and saves, rather than being killed"
run_fake
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
