#!/bin/sh
# Chandlery entrypoint.
#
# tini is PID 1; this script is its only child. It runs the game server and,
# on SIGTERM, hands the server its own in-band stop command via the game's
# stop hook, then waits for the server to exit on its own terms. That is the
# whole point: a bare SIGTERM kills some servers mid-write and loses the world.
#
# Contract with a game image:
#   /usr/local/lib/chandlery/prepare optional executable, run as the game user
#                                   before the server starts. Seeds /data with
#                                   defaults, pre-flights anything that would
#                                   otherwise fail obscurely. Non-zero aborts.
#   /usr/local/lib/chandlery/stop   optional executable, argv[1] = server PID.
#                                   Asks the server to save and quit. Should
#                                   return promptly; we do the waiting.
#                                   Absent => we just forward SIGTERM.
#   $CHANDLERY_CONSOLE              FIFO wired to the server's stdin, so a hook
#                                   (or `chandlery-console`) can type at it.
set -eu

STOP_HOOK=/usr/local/lib/chandlery/stop
PREPARE_HOOK=/usr/local/lib/chandlery/prepare
RUNTIME_DIR="${CHANDLERY_RUNTIME_DIR:-/run/chandlery}"
CHANDLERY_CONSOLE="$RUNTIME_DIR/console"
export CHANDLERY_CONSOLE

log() { printf '[chandlery] %s\n' "$*" >&2; }

[ "$#" -gt 0 ] || { log "no server command given"; exit 64; }

# Started as root (docker run --user 0, or a bind mount that needs adopting)?
# Take ownership of /data, then drop to the game user and carry on as if we
# had started there. Set CHANDLERY_DROP_PRIVS=0 to genuinely stay root.
if [ "$(id -u)" = 0 ] && [ "${CHANDLERY_DROP_PRIVS:-1}" = 1 ]; then
    user="${CHANDLERY_USER:-chandlery}"
    uid="$(id -u "$user")"
    gid="$(id -g "$user")"
    log "running as root; adopting /data, dropping to $user ($uid:$gid)"
    chown "$uid:$gid" /data "$RUNTIME_DIR" 2>/dev/null || true
    exec setpriv --reuid "$uid" --regid "$gid" --clear-groups "$0" "$@"
fi

# A named volume inherits /data's ownership from the image and just works. A
# bind mount does not: it arrives owned by whoever owns the host directory,
# and the server cannot write its world. Say so, with the fix, rather than
# letting the game fail later and less clearly.
for dir in /data; do
    [ -w "$dir" ] && continue
    log "ERROR: $dir is not writable by $(id -un) (uid $(id -u))."
    log "ERROR: it is owned by uid $(stat -c '%u' "$dir" 2>/dev/null || echo '?')."
    log "ERROR: either chown it on the host:  chown -R $(id -u):$(id -g) <host dir>"
    log "ERROR: or start the container as root once, and it will adopt it itself."
    exit 77
done

if [ -x "$PREPARE_HOOK" ]; then
    log "preparing"
    "$PREPARE_HOOK" || { rc=$?; log "prepare hook failed (status $rc); refusing to start"; exit "$rc"; }
fi

mkdir -p "$RUNTIME_DIR"
rm -f "$CHANDLERY_CONSOLE"
mkfifo -m 0600 "$CHANDLERY_CONSOLE"

# Hold the console open read-write for the lifetime of the container. Without a
# writer the server would read EOF on stdin the moment a hook's write closes;
# many servers treat that as "console closed" and shut down.
exec 3<>"$CHANDLERY_CONSOLE"

# The subshell drops fd 3 so the server does not inherit our grip on the
# console, then execs, so $! is the server itself and not a wrapper.
( exec 3<&-; exec "$@" <"$CHANDLERY_CONSOLE" ) &
server_pid=$!
log "server started (pid $server_pid): $*"

alive() { kill -0 "$server_pid" 2>/dev/null; }

graceful_stop() {
    if [ -x "$STOP_HOOK" ]; then
        log "stop requested; running the stop hook"
        if "$STOP_HOOK" "$server_pid"; then
            return 0
        fi
        log "stop hook failed; falling back to SIGTERM"
    else
        log "stop requested; no stop hook, forwarding SIGTERM"
    fi
    kill -TERM "$server_pid" 2>/dev/null || true
}

stop_requested=
trap 'stop_requested=1' TERM INT

# `wait` returns early when a trapped signal arrives, so loop until the server
# is genuinely gone. Docker's stop_grace_period bounds the whole affair; we
# deliberately never escalate to SIGKILL ourselves, because the point of
# waiting is to let the save finish.
status=0
while :; do
    rc=0
    wait "$server_pid" || rc=$?

    if [ -n "$stop_requested" ]; then
        stop_requested=
        if alive; then
            graceful_stop
            continue
        fi
    fi

    alive && continue
    status=$rc
    break
done

log "server exited with status $status"
exit "$status"
