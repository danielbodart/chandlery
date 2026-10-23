#!/bin/sh
# The native tools' shell half (systemd/bin), on the host, with no systemd and
# no Docker: what the units run before, beside and after the game. The units
# themselves are proven in NixOS VMs (nix/tests).
#
# CHANDLERY_TOOLS points at an installed set (the Nix package's bin, in its
# check); by default, the scripts in this checkout.
set -eu
cd "$(dirname "$0")"
. ./lib.sh

repo=$(cd .. && pwd)
TOOLS=${CHANDLERY_TOOLS:-$repo/systemd/bin}
PATH="$TOOLS:$PATH"
CHANDLERY_CONSOLE_SH=${CHANDLERY_CONSOLE_SH:-$repo/images/base/console.sh}
export PATH CHANDLERY_CONSOLE_SH

work=$(mktemp -d)
cleanup() { chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT INT TERM

echo "systemd tools"

# ---- chandlery-set-property ----

props="$work/server.properties"
cat > "$props" <<'EOF'
# Operator's comment
server-name=Dedicated Server
server-port=19132
  server-portv6 = 19133
level-name=My World
EOF

it "rewrites just the keys it is given, keeping comments and order"
chandlery-set-property "$props" server-port=19140 server-portv6=19141 2>/dev/null
assert_equals "# Operator's comment
server-name=Dedicated Server
server-port=19140
server-portv6=19141
level-name=My World" "$(cat "$props")" && pass

it "does not confuse server-port with server-portv6"
chandlery-set-property "$props" server-port=1 2>/dev/null
assert_contains "$(cat "$props")" "server-portv6=19141" \
    && assert_contains "$(cat "$props")" "server-port=1
" && pass

it "appends a key the file does not have"
chandlery-set-property "$props" new-key=x 2>/dev/null
assert_equals "new-key=x" "$(tail -1 "$props")" && pass

it "writes in place, keeping the inode and mode"
chmod 0640 "$props"
before=$(stat -c '%i %a' "$props")
chandlery-set-property "$props" server-port=2 2>/dev/null
assert_equals "$before" "$(stat -c '%i %a' "$props")" && pass

it "leaves an unchanged file alone"
touch -d '2000-01-01' "$props"
out=$(chandlery-set-property "$props" server-port=2 2>&1)
assert_equals "2000-01-01" "$(date -r "$props" +%F)" && assert_equals "" "$out" && pass

it "takes a value literally"
chandlery-set-property "$props" 'motd=a\tb & c' 2>/dev/null
assert_contains "$(cat "$props")" 'motd=a\tb & c' && pass

it "refuses what is not KEY=VALUE"
code=0; chandlery-set-property "$props" =x 2>/dev/null || code=$?
assert_equals 64 "$code" && pass

# ---- chandlery-prepare ----

# A package shaped like the real ones: opt/<game>, lib/chandlery/{game.env,prepare}.
pkg="$work/pkg"
mkdir -p "$pkg/opt/fake/sub" "$pkg/lib/chandlery"
echo stock > "$pkg/opt/fake/server.properties"
echo bin > "$pkg/opt/fake/sub/thing"
cat > "$pkg/lib/chandlery/game.env" <<'EOF'
GAME=fake
CHANDLERY_STAGE=copy-links
CHANDLERY_PROPERTIES=$DATA/server.properties
EOF
cat > "$pkg/lib/chandlery/prepare" <<'EOF'
#!/bin/sh
set -eu
[ -e "$DATA/server.properties" ] || { cp "$CHANDLERY_OPT/fake/server.properties" "$DATA/server.properties"; chmod u+w "$DATA/server.properties"; }
echo "prepared" >> "$DATA/prepare.log"
EOF
chmod 0755 "$pkg/lib/chandlery/prepare"
chmod -R a-w "$pkg"
DATA="$work/data"; CHANDLERY_OPT="$work/opt"
mkdir -p "$DATA" "$CHANDLERY_OPT"
export DATA CHANDLERY_OPT

it "stages a writing game as real directories of links into the package"
chandlery-prepare "$pkg" 2>/dev/null
assert_equals "$pkg/opt/fake/sub/thing" "$(readlink "$CHANDLERY_OPT/fake/sub/thing")" \
    && [ -d "$CHANDLERY_OPT/fake/sub" ] && [ ! -L "$CHANDLERY_OPT/fake/sub" ] \
    && touch "$CHANDLERY_OPT/fake/sub/new" && pass

it "runs the package's prepare, after staging"
assert_equals "prepared" "$(cat "$DATA/prepare.log")" && pass

it "sets keys after prepare has seeded the file"
rm "$DATA/server.properties"
chandlery-prepare "$pkg" --set server-port=19140 2>/dev/null
assert_equals "stock
server-port=19140" "$(cat "$DATA/server.properties")" && pass

it "restages from scratch on every start"
[ ! -e "$CHANDLERY_OPT/fake/sub/new" ] && pass

it "links a reading game's directory whole"
chmod u+w "$pkg/lib/chandlery" "$pkg/lib/chandlery/game.env"
sed -i 's/copy-links/link/' "$pkg/lib/chandlery/game.env"
chandlery-prepare "$pkg" 2>/dev/null
assert_equals "$pkg/opt/fake" "$(readlink "$CHANDLERY_OPT/fake")" && pass

it "resolves a profile once, to the store path behind it"
ln -s "$pkg" "$work/profile"
chandlery-prepare "$work/profile" 2>/dev/null
assert_equals "$pkg/opt/fake" "$(readlink "$CHANDLERY_OPT/fake")" && pass

it "refuses an unknown argument before touching anything"
code=0; chandlery-prepare "$pkg" --bogus 2>/dev/null || code=$?
assert_equals 64 "$code" && pass

it "refuses what is not a package"
code=0; chandlery-prepare "$work" 2>/dev/null || code=$?
assert_equals 66 "$code" && pass

# ---- chandlery-console ----

export CHANDLERY_RUNTIME_DIR="$work/run"
mkdir -p "$CHANDLERY_RUNTIME_DIR/srv"
mkfifo "$CHANDLERY_RUNTIME_DIR/srv/console"

it "types one line at the named server's console"
cat "$CHANDLERY_RUNTIME_DIR/srv/console" > "$work/typed" &
reader=$!
chandlery-console srv say hello world
wait "$reader"
assert_equals "say hello world" "$(cat "$work/typed")" && pass

it "says so when the server has no console"
code=0; chandlery-console nosuch stop 2>/dev/null || code=$?
assert_equals 69 "$code" && pass

it "refuses a name that is a path"
code=0; chandlery-console ../srv stop 2>/dev/null || code=$?
assert_equals 64 "$code" && pass

# ---- chandlery-stop ----

stoppkg="$work/stoppkg"
mkdir -p "$stoppkg/lib/chandlery"
export CHANDLERY_LOCK="$work/running"

it "with no stop hook, returns at once for the kill signal"
chandlery-stop "$stoppkg" 2>/dev/null && pass

cat > "$stoppkg/lib/chandlery/stop" <<EOF
#!/bin/sh
echo "hook ran with [\$#] args" > "$work/hook.log"
EOF
chmod 0755 "$stoppkg/lib/chandlery/stop"

it "runs the hook, then waits until the server has let go of the lock"
flock "$CHANDLERY_LOCK" sleep 2 &
holder=$!
sleep 0.3
start=$(date +%s)
chandlery-stop "$stoppkg" 2>/dev/null
waited=$(( $(date +%s) - start ))
wait "$holder"
if assert_equals "hook ran with [0] args" "$(cat "$work/hook.log")"; then
    if [ "$waited" -ge 1 ]; then pass; else fail "returned after ${waited}s, before the lock was free"; fi
fi

it "returns the hook's failure, for the kill signal"
printf '#!/bin/sh\nexit 5\n' > "$stoppkg/lib/chandlery/stop"
code=0; chandlery-stop "$stoppkg" 2>/dev/null || code=$?
assert_equals 5 "$code" && pass

# ---- chandlery-make-data-dir ----

it "never touches an existing data directory"
mkdir -p "$work/world"; chmod 0705 "$work/world"
chandlery-make-data-dir "$work/world" nobody nogroup
assert_equals 705 "$(stat -c '%a' "$work/world")" && pass

# ---- chandlery-unpack ----

# Image layers as Docker writes them: tars of the paths each step changed, one
# gzip'd, one not, with whiteouts for what a later step deleted.
layers="$work/layers"
mkdir -p "$layers/1/opt/game/dir" "$layers/1/usr/bin" "$layers/2/opt/game/dir" "$layers/2/opt/game/new"
echo a > "$layers/1/opt/game/a"
echo b > "$layers/1/opt/game/dir/b"
echo gone > "$layers/1/opt/game/gone"
echo other > "$layers/1/usr/bin/other"
chmod 0600 "$layers/1/opt/game/a"
ln -s a "$layers/1/opt/game/link"
tar -czf "$layers/1.tar.gz" -C "$layers/1" opt usr
: > "$layers/2/opt/game/.wh.gone"
: > "$layers/2/opt/game/dir/.wh..wh..opq"
echo c > "$layers/2/opt/game/dir/c"
echo d > "$layers/2/opt/game/new/d"
tar -cf "$layers/2.tar" -C "$layers/2" opt
mkdir -p "$layers/3"
echo x > "$layers/3/elsewhere"
tar -cf "$layers/3.tar" -C "$layers/3" elsewhere

it "stacks the layers in order, keeping only the subtree"
chandlery-unpack --blobs "$work/unpacked" opt/game "$layers/1.tar.gz" "$layers/2.tar" "$layers/3.tar"
assert_equals "opt/game/a
opt/game/dir/c
opt/game/link
opt/game/new/d" "$(cd "$work/unpacked" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)" \
    && assert_equals a "$(cat "$work/unpacked/opt/game/link")" && pass

it "honours whiteouts: a deleted file, and an opaque directory"
if [ -e "$work/unpacked/opt/game/gone" ] || [ -e "$work/unpacked/opt/game/dir/b" ] \
    || [ -e "$work/unpacked/opt/game/.wh.gone" ]; then
    fail "whiteouts left behind: $(find "$work/unpacked")"
else
    pass
fi

it "leaves the tree readable by whoever the game runs as"
assert_equals 644 "$(stat -c '%a' "$work/unpacked/opt/game/a")" && pass

mkdir -p "$layers/evil/opt/game"
ln -s /etc "$layers/evil/opt/game/etc"
tar -cf "$layers/evil-link.tar" -C "$layers/evil" opt
printf 'x' > "$layers/x"
tar -cf "$layers/evil-dots.tar" -C "$layers" --transform 's|^x$|opt/game/../../x|' x

it "refuses a layer that links out of the tree"
code=0; chandlery-unpack --blobs "$work/evil1" opt/game "$layers/evil-link.tar" 2>/dev/null || code=$?
assert_equals 65 "$code" && pass

it "refuses a layer that names a '..'"
code=0; chandlery-unpack --blobs "$work/evil2" opt/game "$layers/evil-dots.tar" 2>/dev/null || code=$?
assert_equals 65 "$code" && [ ! -e "$work/x" ] && pass

it "refuses a subtree that is not below the image's root"
code=0; chandlery-unpack --blobs "$work/evil3" ../opt "$layers/2.tar" 2>/dev/null || code=$?
assert_equals 64 "$code" && pass

# ---- chandlery-unpack IMAGE DEST: a package from a registry on disk ----

registry="$work/v2"
OCI_REGISTRY_URL="file://$registry"
export OCI_REGISTRY_URL
blob() {  # $1 = repository, $2 = file; prints its digest, stores it as a blob
    d="sha256:$(sha256sum < "$2" | cut -d' ' -f1)"
    mkdir -p "$registry/$1/blobs" "$registry/$1/manifests"
    cp "$2" "$registry/$1/blobs/$d"
    echo "$d"
}
# An image shaped as images/<game>/Dockerfile builds one: the base's console,
# a Debian step, the game under /opt, the adapter under /usr/local.
publish_game() {  # $1 = game, $2 = CMD as JSON; prints REPOSITORY@DIGEST
    repo=chandlery/$1 src="$work/img-$1"
    mkdir -p "$src/base/usr/local/bin" "$src/deb/usr/bin" "$src/game/opt/$1" \
        "$src/adapter/usr/local/bin" "$src/adapter/usr/local/lib/chandlery"
    cp "$repo_root/images/base/console.sh" "$src/base/usr/local/bin/chandlery-console"
    echo entry > "$src/base/usr/local/bin/chandlery-entrypoint"
    echo debian > "$src/deb/usr/bin/other"
    echo game > "$src/game/opt/$1/server"
    printf '#!/bin/sh\nexec /usr/local/lib/chandlery/prepare "$@"\n' > "$src/adapter/usr/local/bin/$1-server"
    printf '#!/bin/sh\nchandlery-console stop\n' > "$src/adapter/usr/local/lib/chandlery/stop"
    printf '#!/bin/sh\nexec /usr/local/bin/probe\n' > "$src/adapter/usr/local/lib/chandlery/health"
    printf '#!/bin/sh\necho probed\n' > "$src/adapter/usr/local/bin/probe"
    for l in base deb game adapter; do tar -czf "$src/$l.tgz" -C "$src/$l" .; done
    cat > "$src/config" <<JSON
{"config":{"Env":["PATH=/usr/local/bin:/usr/bin","CHANDLERY_USER=chandlery","JAVA_HOME=/opt/java","GAME_VERSION=1.2.3"],
  "Cmd":$2},
 "history":[
  {"created_by":"COPY --chmod=0755 console.sh /usr/local/bin/chandlery-console # buildkit"},
  {"created_by":"RUN apt-get install -y libatomic1"},
  {"created_by":"ENV GAME_VERSION=1.2.3","empty_layer":true},
  {"created_by":"COPY --chown=chandlery:chandlery /buckets/00/ /opt/$1/ # buildkit"},
  {"created_by":"COPY --chmod=0755 images/$1/run /usr/local/bin/$1-server # buildkit"}
 ]}
JSON
    cat > "$src/manifest" <<JSON
{"schemaVersion":2,"config":{"digest":"$(blob "$repo" "$src/config")"},
 "layers":[{"digest":"$(blob "$repo" "$src/base.tgz")"},{"digest":"$(blob "$repo" "$src/deb.tgz")"},
           {"digest":"$(blob "$repo" "$src/game.tgz")"},{"digest":"$(blob "$repo" "$src/adapter.tgz")"}]}
JSON
    d=$(blob "$repo" "$src/manifest")
    cp "$src/manifest" "$registry/$repo/manifests/$d"
    cp "$src/manifest" "$registry/$repo/manifests/latest"
    echo "ghcr.io/$repo@$d"
}
repo_root=$(cd .. && pwd)

it "lays an image out as a package: the game, the adapter, the image's own console"
ref=$(publish_game bedrock '["/usr/local/bin/bedrock-server"]')
chandlery-unpack "$ref" "$work/packages/bedrock-1.2.3" 2>/dev/null
p="$work/packages/bedrock-1.2.3"
assert_equals "bin/bedrock-server
bin/chandlery-server
lib/chandlery/game.env
lib/chandlery/health
lib/chandlery/stop
libexec/chandlery/chandlery-console
libexec/chandlery/probe
opt/bedrock/server" "$(cd "$p" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)" && pass

it "points the adapter's absolute paths at the package"
assert_contains "$(cat "$p/bin/bedrock-server")" "exec $p/lib/chandlery/prepare" \
    && assert_equals probed "$("$p/lib/chandlery/health")" && pass

it "writes game.env from the image's ENV, without its Debian's, and the game's readiness"
assert_equals "GAME=bedrock
GAME_VERSION='1.2.3'
CHANDLERY_READY='Server started\.'
CHANDLERY_STAGE=copy-links
CHANDLERY_PROPERTIES=/data/server.properties
CHANDLERY_IMAGE='$ref'" "$(cat "$p/lib/chandlery/game.env")" && pass

it "is a package chandlery-prepare and chandlery-stop take"
mkdir -p "$work/opt2"
CHANDLERY_OPT="$work/opt2" chandlery-prepare "$p" 2>/dev/null
mkfifo "$work/console2"
( read -r line < "$work/console2"; echo "$line" > "$work/typed" ) &
CHANDLERY_CONSOLE="$work/console2" chandlery-stop "$p" 2>/dev/null
wait
assert_equals "$p/opt/bedrock" "$(readlink -f "$work/opt2/bedrock/server" | xargs dirname)" \
    && assert_equals stop "$(cat "$work/typed")" && pass

it "keeps the image's CMD arguments as CHANDLERY_ARGS, and drops a PID-signalling stop hook"
ref=$(publish_game valheim '["/usr/local/bin/valheim-server","-name","Chandlery","-port","2456"]')
chandlery-unpack "ghcr.io/chandlery/valheim" "$work/packages/valheim" 2>/dev/null
assert_contains "$(cat "$work/packages/valheim/lib/chandlery/game.env")" "CHANDLERY_ARGS='-name Chandlery -port 2456'" \
    && [ ! -e "$work/packages/valheim/lib/chandlery/stop" ] && pass

it "refuses to unpack over an existing directory"
code=0; chandlery-unpack "$ref" "$work/packages/valheim" 2>/dev/null || code=$?
assert_equals 73 "$code" && pass

it "refuses an image that is not a Chandlery game"
code=0; chandlery-unpack ghcr.io/someone/minecraft:1 "$work/packages/mc" 2>/dev/null || code=$?
assert_equals 64 "$code" && pass

it "refuses a manifest that does not hash to the digest asked for"
cp "$registry/chandlery/bedrock/manifests/latest" "$registry/chandlery/bedrock/manifests/sha256:$(printf '%064d' 1)"
code=0; chandlery-unpack "ghcr.io/chandlery/bedrock@sha256:$(printf '%064d' 1)" "$work/packages/b2" 2>/dev/null || code=$?
assert_equals 65 "$code" && [ ! -e "$work/packages/b2" ] && pass

it "sets the keys CHANDLERY_SET lists, after its arguments"
rm -f "$DATA/server.properties"
CHANDLERY_SET="server-port=19150 server-portv6=19151" chandlery-prepare "$pkg" 2>/dev/null
assert_equals "stock
server-port=19150
server-portv6=19151" "$(cat "$DATA/server.properties")" && pass

summary "systemd tools"
