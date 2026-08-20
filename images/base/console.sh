#!/bin/sh
# Type a command at the running server's console, e.g.
#   docker exec <container> chandlery-console say hello
# Writes are line-oriented and go to the FIFO the entrypoint wired to stdin.
set -eu

CONSOLE="${CHANDLERY_CONSOLE:-${CHANDLERY_RUNTIME_DIR:-/run/chandlery}/console}"

[ "$#" -gt 0 ] || { echo "usage: chandlery-console <command> [args...]" >&2; exit 64; }
[ -p "$CONSOLE" ] || { echo "chandlery-console: no console at $CONSOLE" >&2; exit 69; }

printf '%s\n' "$*" > "$CONSOLE"
