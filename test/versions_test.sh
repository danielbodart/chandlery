#!/bin/sh
# nix/update-versions: the pin CI rewrites after each image it publishes. On a
# copy of a fixture, with jq and nothing else.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

update=../nix/update-versions
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
VERSIONS_JSON="$work/versions.json"
export VERSIONS_JSON

sha_a=$(printf a | sha256sum | cut -d' ' -f1)
sha_b=$(printf b | sha256sum | cut -d' ' -f1)

reset() {
    cat > "$VERSIONS_JSON" <<JSON
{
  "bedrock": {
    "version": "1.0.0.1",
    "sha256": "$sha_a"
  },
  "hytale": {
    "version": "0.1"
  }
}
JSON
}

echo "versions"

it "rewrites Bedrock's version and sha256"
reset
$update bedrock 1.0.0.2 "$sha_b" >/dev/null
assert_equals "1.0.0.2 $sha_b" "$(jq -r '.bedrock | "\(.version) \(.sha256)"' "$VERSIONS_JSON")" && pass

it "keeps the other games, the key order and the indent: one hunk per game"
assert_equals "{
  \"bedrock\": {
    \"version\": \"1.0.0.2\",
    \"sha256\": \"$sha_b\"
  },
  \"hytale\": {
    \"version\": \"0.1\"
  }
}" "$(cat "$VERSIONS_JSON")" && pass

it "leaves the file untouched when nothing changed"
touch -d '2000-01-01' "$VERSIONS_JSON"
out=$($update bedrock 1.0.0.2 "$sha_b")
assert_equals "2000-01-01" "$(date -r "$VERSIONS_JSON" +%F)" \
    && assert_equals "update-versions: bedrock unchanged" "$out" && pass

it "refuses a sha256 that is not one"
reset
code=0; $update bedrock 1.0.0.2 nothex 2>/dev/null || code=$?
assert_equals 65 "$code" && assert_equals "$sha_a" "$(jq -r .bedrock.sha256 "$VERSIONS_JSON")" && pass

it "refuses a version that is not one"
code=0; $update bedrock latest "$sha_b" 2>/dev/null || code=$?
assert_equals 65 "$code" && pass

it "refuses a game it does not know"
code=0; $update minecraft 1 "$sha_b" 2>/dev/null || code=$?
assert_equals 64 "$code" && pass

it "keeps the file's mode"
chmod 0644 "$VERSIONS_JSON"
$update bedrock 1.0.0.3 "$sha_b" >/dev/null
assert_equals 644 "$(stat -c %a "$VERSIONS_JSON")" && pass

# ---- oci: a published image, from a registry on disk ----

registry="$work/v2"
repo=chandlery/hytale
mkdir -p "$registry/$repo/manifests" "$registry/$repo/blobs"
OCI_REGISTRY_URL="file://$registry"
export OCI_REGISTRY_URL
l() { printf 'sha256:%064d' "$1"; }

# An image of four layers: a base, two of the game, our own script. Its config
# history has empty steps between them, as a Dockerfile's ENV and LABEL do.
publish() {  # $1 = revision, $2 = the game's top layer; prints IMAGE@DIGEST
    cat > "$work/config" <<JSON
{"config":{"Labels":{"org.opencontainers.image.revision":"$1"}},
 "history":[
  {"created_by":"# debian.tar.xz /"},
  {"created_by":"ENV JAVA_HOME=/opt/java/openjdk","empty_layer":true},
  {"created_by":"COPY --chown=chandlery:chandlery /buckets/00/ /opt/hytale/ # buildkit"},
  {"created_by":"COPY --chmod=0755 images/hytale/run /usr/local/bin/hytale-server # buildkit"},
  {"created_by":"COPY --chown=chandlery:chandlery /bin-layer/Server/ /opt/hytale/Server/ # buildkit"},
  {"created_by":"ENV HYTALE_VERSION=0.7.4","empty_layer":true}
 ]}
JSON
    config_digest="sha256:$(sha256sum "$work/config" | cut -d' ' -f1)"
    cp "$work/config" "$registry/$repo/blobs/$config_digest"
    cat > "$work/manifest" <<JSON
{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json",
 "config":{"digest":"$config_digest"},
 "layers":[{"digest":"$(l 1)"},{"digest":"$(l 2)"},{"digest":"$(l 3)"},{"digest":"$2"}]}
JSON
    manifest_digest="sha256:$(sha256sum "$work/manifest" | cut -d' ' -f1)"
    cp "$work/manifest" "$registry/$repo/manifests/$manifest_digest"
    echo "ghcr.io/$repo@$manifest_digest"
}

it "pins an image by digest, with the layers that write its /opt/<game>, in order"
reset
ref=$(publish abc123 "$(l 4)")
$update oci hytale "$ref" 0.7.4 >/dev/null
assert_equals "0.7.4 ghcr.io/$repo ${ref#*@} abc123 $(l 2),$(l 4)" \
    "$(jq -r '.hytale | "\(.version) \(.image) \(.digest) \(.revision) \(.layers | join(","))"' "$VERSIONS_JSON")" \
    && assert_equals "$sha_a" "$(jq -r .bedrock.sha256 "$VERSIONS_JSON")" && pass

it "leaves the pin alone for an image rebuilt only for our own code"
touch -d '2000-01-01' "$VERSIONS_JSON"
ref2=$(publish def456 "$(l 4)")
out=$($update oci hytale "$ref2" 0.7.4)
assert_equals "update-versions: hytale unchanged" "$out" \
    && assert_equals "2000-01-01" "$(date -r "$VERSIONS_JSON" +%F)" && pass

it "re-pins when the game's layers change"
ref3=$(publish def456 "$(l 5)")
$update oci hytale "$ref3" 0.7.5 >/dev/null
assert_equals "0.7.5 ${ref3#*@} def456 $(l 2),$(l 5)" \
    "$(jq -r '.hytale | "\(.version) \(.digest) \(.revision) \(.layers | join(","))"' "$VERSIONS_JSON")" && pass

it "adds the game's own keys after its version"
$update oci hytale "$ref3" 0.7.5 buildId=42 >/dev/null
assert_equals "version buildId image digest revision layers" \
    "$(jq -r '.hytale | keys_unsorted | join(" ")' "$VERSIONS_JSON")" \
    && assert_equals 42 "$(jq -r .hytale.buildId "$VERSIONS_JSON")" && pass

it "refuses a manifest that does not hash to the digest asked for"
cp "$work/manifest" "$registry/$repo/manifests/$(l 9)"
code=0; $update oci hytale "ghcr.io/$repo@$(l 9)" 0.7.6 2>/dev/null || code=$?
assert_equals 65 "$code" && assert_equals 0.7.5 "$(jq -r .hytale.version "$VERSIONS_JSON")" && pass

it "says so when the image cannot be fetched"
code=0; $update oci hytale "ghcr.io/$repo@$(l 8)" 0.7.6 2>/dev/null || code=$?
assert_equals 69 "$code" && pass

it "refuses a reference without a digest"
code=0; $update oci hytale "ghcr.io/$repo:0.7.6" 0.7.6 2>/dev/null || code=$?
assert_equals 65 "$code" && pass

summary "versions"
