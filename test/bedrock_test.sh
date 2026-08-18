#!/bin/sh
# Bedrock image. The structural checks below are the ones that matter for
# "image = version": the tag, the label and the bits on disk have to agree.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

IMAGE=chandlery/bedrock:test
PONG_IMAGE=chandlery/test-raknet-pong:test
VERSION="${BEDROCK_VERSION:?set BEDROCK_VERSION}"
CONTAINER=chandlery-bedrock-test-$$

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# Run a shell in the image without starting a server.
inspect() { docker run --rm --entrypoint /bin/sh "$IMAGE" -c "$1"; }

echo "bedrock $VERSION"

it "bakes the server in, so the image needs no download to run"
assert_equals "yes" "$(inspect '[ -x /opt/bedrock/bedrock_server ] && echo yes')" && pass

it "labels the image with the version in its tag"
assert_equals "$VERSION" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" && pass

it "drops build-time artefacts that cannot run a game"
# The static link library, and the ~311MB debug symbols older releases shipped.
assert_equals "" "$(inspect 'ls /opt/bedrock/*.a /opt/bedrock/*debug_symbols* 2>/dev/null')" && pass

it "keeps state on /data and the game in the image"
links=$(inspect 'for f in server.properties allowlist.json permissions.json worlds; do
                     printf "%s->%s " "$f" "$(readlink /opt/bedrock/$f)"; done')
assert_equals \
  "server.properties->/data/server.properties allowlist.json->/data/allowlist.json permissions.json->/data/permissions.json worlds->/data/worlds " \
  "$links" && pass

it "ships the stock config as a seed, not as live state"
assert_equals "yes" "$(inspect '[ -f /opt/bedrock/.defaults/server.properties ] && echo yes')" && pass

it "declares a health check"
assert_contains "$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")" \
    "/usr/local/lib/chandlery/health" && pass

it "seeds /data on first run, and leaves an existing world alone"
cleanup
world=$(mktemp -d)
chown 1000:1000 "$world"
# The server cannot start here (see the IPv6 check below), but prepare runs first.
docker run --rm -v "$world:/data" "$IMAGE" >/dev/null 2>&1 || true
if [ -f "$world/server.properties" ] && [ -d "$world/worlds" ]; then
    echo "server-name=Mine" > "$world/server.properties"
    docker run --rm -v "$world:/data" "$IMAGE" >/dev/null 2>&1 || true
    assert_equals "server-name=Mine" "$(cat "$world/server.properties")" \
        "prepare overwrote an existing config" && pass
else
    fail "prepare did not seed /data (got: $(ls -A "$world" 2>/dev/null | tr '\n' ' '))"
fi
rm -rf "$world"

it "explains itself on a kernel with no IPv6 support"
# BDS opens an IPv6 socket and, failing, blames its ports. We warn rather than
# refuse — an IPv4-only host is fine, and only ipv6.disable=1 actually breaks it.
if [ -e /proc/net/if_inet6 ]; then
    printf 'skipped (this kernel has IPv6 support)\n'
    TESTS_RUN=$((TESTS_RUN - 1))
else
    out=$(docker run --rm "$IMAGE" 2>&1 || true)
    assert_contains "$out" "no IPv6 support at all" \
        && assert_contains "$out" "IPv6 connectivity is NOT required" \
        && pass
fi

it "reports healthy when the server answers a RakNet ping"
cleanup
docker run -d --name "$CONTAINER" --entrypoint /usr/local/bin/raknet-pong \
    "$PONG_IMAGE" 19132 >/dev/null
if wait_for_log "$CONTAINER" "raknet-pong: listening"; then
    if out=$(docker exec "$CONTAINER" /usr/local/lib/chandlery/health 2>&1); then
        assert_contains "$out" "version=" && pass
    else
        fail "health probe failed against a responding server: $out"
    fi
fi

it "reports unhealthy when nothing is listening"
# The distinction the LinuxGSM probe got wrong, in the direction that matters.
if docker exec "$CONTAINER" env CHANDLERY_HEALTH_PORT=19199 \
        /usr/local/lib/chandlery/health >/dev/null 2>&1; then
    fail "health probe passed against a dead port"
else
    pass
fi

it "reads the port from server.properties rather than assuming 19132"
cleanup
docker run -d --name "$CONTAINER" --entrypoint /usr/local/bin/raknet-pong \
    "$PONG_IMAGE" 19140 >/dev/null
if wait_for_log "$CONTAINER" "raknet-pong: listening"; then
    docker exec --user root "$CONTAINER" sh -c 'printf "server-port=19140\n" > /data/server.properties'
    if docker exec "$CONTAINER" /usr/local/lib/chandlery/health >/dev/null 2>&1; then pass; else
        fail "health probe ignored server-port=19140"
    fi
fi

it "runs the server as the non-root chandlery user"
assert_equals "chandlery" "$(docker inspect -f '{{.Config.User}}' "$IMAGE")" && pass

summary "bedrock"
