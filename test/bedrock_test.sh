#!/bin/sh
# Bedrock image, baked. "image = version" is now literal: the server the tag
# names is in the image, split into a stable asset layer and the volatile
# bedrock_server layer (bedrock/Dockerfile). These checks prove the layout the
# image bakes and the adapter that runs it — no cache volume, no first-start
# fetch, no network.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

IMAGE=chandlery/bedrock:test
PONG_IMAGE=chandlery/test-raknet-pong:test
VERSION="${BEDROCK_VERSION:?set BEDROCK_VERSION}"
CONTAINER=chandlery-bedrock-test-$$
DATA_VOL=chandlery-bedrock-data-$$

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$DATA_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Run a shell in the image without starting a server.
inspect() { docker run --rm --entrypoint /bin/sh "$IMAGE" -c "$1"; }

echo "bedrock $VERSION"

it "bakes the server it names, executable, at /opt/bedrock"
assert_equals "yes" "$(inspect '[ -x /opt/bedrock/bedrock_server ] && echo yes')" && pass

it "records the version in its tag's label and its environment"
assert_equals "$VERSION" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" \
  && assert_equals "$VERSION" "$(inspect 'echo "$BEDROCK_VERSION"')" && pass

it "ships the adapter and needs no runtime fetch machinery"
# Baked: the fetch/cache path is gone; curl/unzip do not ride into the runtime.
assert_equals "yes" "$(inspect '[ -x /usr/local/lib/chandlery/prepare ] &&
                                 [ -x /usr/local/lib/chandlery/health ] &&
                                 [ -x /usr/local/lib/chandlery/stop ] &&
                                 [ -x /usr/local/bin/bedrock-server ] &&
                                 [ ! -e /usr/local/lib/chandlery/fetch ] &&
                                 ! command -v curl >/dev/null 2>&1 &&
                                 ! command -v unzip >/dev/null 2>&1 && echo yes')" && pass

it "drops the build-time leftovers the zip carries"
assert_equals "yes" "$(inspect '[ ! -e /opt/bedrock/libMinecraft.Server.Lib.a ] &&
                                 [ ! -e /opt/bedrock/bedrock_server_debug_symbols.debug ] && echo yes')" && pass

it "puts bedrock_server in a layer of its own, above the bucketed assets"
# The whole layering claim: the binary is the per-release delta, so it must not
# share a layer with the assets that stay put, and the assets are split into
# bucket layers that dedupe. docker history lists the binary COPY and the buckets.
hist=$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE")
buckets=$(printf '%s\n' "$hist" | grep -c '/buckets/[0-9]')
assert_contains "$hist" "/opt/bedrock/bedrock_server" \
  && [ "$buckets" -ge 8 ] \
  && pass

it "normalises baked mtimes to the build epoch, so unchanged assets dedupe"
# A fresh mtime per release is what makes an identical asset tree re-pull; the
# build stamps them all to SOURCE_DATE_EPOCH (0). Check the asset tree carries it.
epochs=$(inspect 'find /opt/bedrock/resource_packs -type f -printf "%T@\n" | sort -u | head -5')
assert_equals "0.0000000000" "$epochs" && pass

it "declares a health check"
assert_contains "$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")" \
    "/usr/local/lib/chandlery/health" && pass

it "seeds /data from the baked version, and wires the game dir out to it"
docker volume create "$DATA_VOL" >/dev/null
docker run --rm -v "$DATA_VOL:/data" alpine sh -c 'chown 1000:1000 /data'
# The game dir is baked into the image, so prepare's symlinks live in this
# container's writable layer only — run prepare and read them in one container.
links=$(docker run --rm -v "$DATA_VOL:/data" --entrypoint /bin/sh "$IMAGE" -c '
    /usr/local/lib/chandlery/prepare >/dev/null 2>&1 || true
    cd /opt/bedrock
    for f in server.properties allowlist.json permissions.json worlds; do
        printf "%s->%s " "$f" "$(readlink "$f")"
    done')
assert_equals \
  "server.properties->/data/server.properties allowlist.json->/data/allowlist.json permissions.json->/data/permissions.json worlds->/data/worlds " \
  "$links" \
  && assert_equals "yes" "$(docker run --rm -v "$DATA_VOL:/data" alpine sh -c \
       '[ -f /data/server.properties ] && [ -d /data/worlds ] && echo yes')" && pass

it "leaves an existing world's config alone on a later start"
docker run --rm -v "$DATA_VOL:/data" alpine sh -c 'echo "server-name=Mine" > /data/server.properties'
docker run --rm -v "$DATA_VOL:/data" \
    --entrypoint /usr/local/lib/chandlery/prepare "$IMAGE" >/dev/null 2>&1 || true
assert_equals "server-name=Mine" \
    "$(docker run --rm -v "$DATA_VOL:/data" alpine cat /data/server.properties)" && pass

it "explains itself on a kernel with no IPv6 support"
if [ -e /proc/net/if_inet6 ]; then
    printf 'skipped (this kernel has IPv6 support)\n'
    TESTS_RUN=$((TESTS_RUN - 1))
else
    out=$(docker run --rm --entrypoint /usr/local/lib/chandlery/prepare "$IMAGE" 2>&1 || true)
    assert_contains "$out" "no IPv6 support at all" \
        && assert_contains "$out" "IPv6 connectivity is NOT required" && pass
fi

it "reports healthy when the server answers a RakNet ping"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
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
if docker exec "$CONTAINER" env CHANDLERY_HEALTH_PORT=19199 \
        /usr/local/lib/chandlery/health >/dev/null 2>&1; then
    fail "health probe passed against a dead port"
else
    pass
fi

it "reads the port from server.properties rather than assuming 19132"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
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
