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

summary "versions"
