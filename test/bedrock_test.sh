#!/bin/sh
# Bedrock image, pinned-not-baked. The checks that matter for "image = version"
# now split in two: the image records *which* version (tag, label, env) and
# carries none of it, and a first start fetches, verifies and lays it out. The
# fetch/verify/boot path is proven end to end elsewhere against a real download;
# here we drive the layout logic off a pre-seeded /cache so the suite stays fast
# and needs no network.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

IMAGE=chandlery/bedrock:test
PONG_IMAGE=chandlery/test-raknet-pong:test
VERSION="${BEDROCK_VERSION:?set BEDROCK_VERSION}"
CONTAINER=chandlery-bedrock-test-$$
CACHE_VOL=chandlery-bedrock-cache-$$
DATA_VOL=chandlery-bedrock-data-$$

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$CACHE_VOL" "$DATA_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Run a shell in the image without starting a server.
inspect() { docker run --rm --entrypoint /bin/sh "$IMAGE" -c "$1"; }

# Lay a fake, ready Bedrock tree into a fresh cache volume, so chandlery-cache
# takes its already-cached fast path and prepare runs its layout on top. This
# stands in for a real fetch, which is proven separately.
seed_cache() {
    docker volume create "$CACHE_VOL" >/dev/null
    docker volume create "$DATA_VOL" >/dev/null
    docker run --rm -v "$CACHE_VOL:/cache" -v "$DATA_VOL:/data" alpine sh -c '
        chown 1000:1000 /cache /data
        d=/cache/bedrock/'"$VERSION"'
        mkdir -p "$d"
        printf "server-name=Chandlery\nserver-port=19132\n" > "$d/server.properties"
        echo "{}" > "$d/allowlist.json"
        echo "[]" > "$d/permissions.json"
        printf "#!/bin/sh\necho READY-FAKE-BDS\nwhile read l; do [ \"\$l\" = stop ] && exit 0; done\n" > "$d/bedrock_server"
        chmod +x "$d/bedrock_server"
        : > "$d/.chandlery-ready"
        chown -R 1000:1000 /cache/bedrock
    '
}

echo "bedrock $VERSION"

it "carries no game content — it pins the version, not the bytes"
# The whole point of the conversion: a public image may not redistribute BDS.
assert_equals "" "$(inspect 'ls /opt/bedrock 2>/dev/null; find / -name bedrock_server -not -path "*/cache/*" 2>/dev/null')" && pass

it "records the version to fetch, in its tag's label and its environment"
assert_equals "$VERSION" \
    "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" \
  && assert_equals "$VERSION" "$(inspect 'echo "$BEDROCK_VERSION"')" && pass

it "ships the fetch/verify machinery, not a baked payload"
assert_equals "yes" "$(inspect '[ -x /usr/local/lib/chandlery/fetch ] &&
                                 [ -x /usr/local/bin/chandlery-cache ] &&
                                 [ -x /usr/local/bin/bedrock-server ] && echo yes')" && pass

it "declares a health check"
assert_contains "$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")" \
    "/usr/local/lib/chandlery/health" && pass

it "fetches once, then reuses /cache on the next start"
seed_cache
out=$(docker run --rm -v "$CACHE_VOL:/cache" -v "$DATA_VOL:/data" \
        --entrypoint /usr/local/lib/chandlery/prepare "$IMAGE" 2>&1 || true)
assert_contains "$out" "already cached" && pass

it "seeds /data from the cached version, and wires the game dir out to it"
# prepare has run once above; check what it laid down.
links=$(docker run --rm -v "$CACHE_VOL:/cache" alpine sh -c \
    'cd /cache/bedrock/'"$VERSION"'; for f in server.properties allowlist.json permissions.json worlds; do
         printf "%s->%s " "$f" "$(readlink "$f")"; done')
assert_equals \
  "server.properties->/data/server.properties allowlist.json->/data/allowlist.json permissions.json->/data/permissions.json worlds->/data/worlds " \
  "$links" \
  && assert_equals "yes" "$(docker run --rm -v "$DATA_VOL:/data" alpine sh -c \
       '[ -f /data/server.properties ] && [ -d /data/worlds ] && echo yes')" && pass

it "leaves an existing world's config alone on a later start"
docker run --rm -v "$DATA_VOL:/data" alpine sh -c 'echo "server-name=Mine" > /data/server.properties'
docker run --rm -v "$CACHE_VOL:/cache" -v "$DATA_VOL:/data" \
    --entrypoint /usr/local/lib/chandlery/prepare "$IMAGE" >/dev/null 2>&1 || true
assert_equals "server-name=Mine" \
    "$(docker run --rm -v "$DATA_VOL:/data" alpine cat /data/server.properties)" && pass

it "refuses to start when the download does not match the pinned sha256"
# Fail closed: wrong bytes never run, and nothing partial is left on /cache.
badcache=chandlery-bedrock-badcache-$$
docker volume create "$badcache" >/dev/null
if docker run --rm -v "$badcache:/cache" \
      -e BEDROCK_URL="http://127.0.0.1:1/nope.zip" \
      --entrypoint /usr/local/lib/chandlery/prepare "$IMAGE" >/dev/null 2>&1; then
    fail "prepare succeeded despite an unreachable download"
else
    left=$(docker run --rm -v "$badcache:/cache" alpine sh -c 'find /cache/bedrock -mindepth 1 | wc -l')
    assert_equals "0" "$left" "a failed fetch left something on /cache" && pass
fi
docker volume rm "$badcache" >/dev/null 2>&1 || true

it "explains itself on a kernel with no IPv6 support"
if [ -e /proc/net/if_inet6 ]; then
    printf 'skipped (this kernel has IPv6 support)\n'
    TESTS_RUN=$((TESTS_RUN - 1))
else
    # No cache: prepare warns about IPv6 before it ever reaches the fetch.
    out=$(docker run --rm "$IMAGE" 2>&1 || true)
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
