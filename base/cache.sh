#!/bin/sh
# chandlery-cache: fetch a pinned game payload into /cache exactly once.
#
# The images carry no game content — that would be redistributing it, which the
# licences forbid (PLAN 7.3). Instead the image pins a version, precisely enough
# that it cannot run anything else, and the bytes are fetched from upstream on
# first start and kept on the /cache volume. Only the first start of a given
# version pays the download; a container recreate reuses what is already there.
#
# This wraps the part every game shares, and gets wrong differently each time if
# left to each: a content-addressed cache directory, an atomic populate-or-reuse,
# and a readiness marker written *last*, so a fetch interrupted anywhere is
# retried on the next start rather than trusted as complete.
#
# Usage:
#   dir=$(chandlery-cache <namespace> <key> <populate-cmd> [args...])
#
# <populate-cmd> is run with a fresh, empty staging directory as its final
# argument; it must fill that directory with the payload and exit non-zero if it
# cannot. On success the ready directory's path is printed on stdout (and only
# that — everything else goes to stderr). A non-zero populate leaves no marker,
# so the next start retries from clean rather than running a half-download.
set -eu

[ "$#" -ge 3 ] || { echo "usage: chandlery-cache <namespace> <key> <populate-cmd> [args...]" >&2; exit 64; }

ns=$1
key=$2
shift 2

root="${CHANDLERY_CACHE:-/cache}/$ns"
dir="$root/$key"

log() { printf '[cache] %s\n' "$*" >&2; }

# The marker is the whole contract: present means every byte below it landed.
if [ -f "$dir/.chandlery-ready" ]; then
    log "$ns $key already cached"
    printf '%s\n' "$dir"
    exit 0
fi

# A directory without the marker is a fetch that did not finish. Do not trust a
# single file of it.
if [ -e "$dir" ]; then
    log "discarding an incomplete $ns $key"
    rm -rf "$dir"
fi

# Staging lives under the same namespace dir, so it is on the same filesystem as
# the final path and the move into place is an atomic rename, never a copy.
staging="$root/.staging.$key.$$"
mkdir -p "$root"
rm -rf "$staging"
mkdir -p "$staging"
# Any failure — populate, signal, disk full — takes the half-built staging dir
# with it, so nothing partial is ever left in /cache.
trap 'rm -rf "$staging"' EXIT INT TERM

log "fetching $ns $key"
"$@" "$staging"

# Marker last: it is the promise that the populate above completed. Then swap the
# whole tree into place in one rename.
: > "$staging/.chandlery-ready"
mv "$staging" "$dir"
trap - EXIT INT TERM

log "cached $ns $key"
printf '%s\n' "$dir"
