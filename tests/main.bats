#!/usr/bin/env bats
#
# The orchestration: which of pull, build, push, boot, prepare and run happen, in
# what order, on each path. The steps themselves are tested on their own; here they
# are stand-ins that record their calls, over a store that really keeps what is pushed.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    S="$BATS_TEST_TMPDIR/scripts"; mkdir -p "$S"
    cp "$REPO/scripts/main.sh" "$S/"
    export CALLS="$BATS_TEST_TMPDIR/calls" ROOM="$BATS_TEST_TMPDIR/room" STORE="$BATS_TEST_TMPDIR/store"
    : > "$CALLS"; : > "$ROOM"
    cat > "$S/stub" <<'STUB'
#!/bin/bash
f="$(basename "$0")"
printf '%s %s\n' "$f" "$*" >> "$CALLS"
# STUB_FAIL: a glob over "<step> <args>"; a match fails the step, with STUB_FAIL_STATUS (default
# 1), printing STUB_SAY if set and otherwise nothing, as a step that fails silently would
case "$f $*" in ${STUB_FAIL:-//}) [ -z "${STUB_SAY:-}" ] || echo "$STUB_SAY"; exit "${STUB_FAIL_STATUS:-1}" ;; esac
newid() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
case "$f $1" in key.sh\ --base|key.sh\ --layer|key.sh\ --prepared) echo "${MVM_BASE_RECIPE-unset}" >> "$BATS_TEST_TMPDIR/recipe-seen" ;; esac
case "$f $1" in
  "key.sh --recipe") echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  "key.sh --prepared") echo 3333333333333333333333333333333333333333333333333333333333333333 ;;
  "key.sh --layer") echo 2222222222222222222222222222222222222222222222222222222222222222 ;;
  "key.sh "*) echo 1111111111111111111111111111111111111111111111111111111111111111 ;;
  # the store keeps what is pushed under its key; a push is skipped when the key is there,
  # unless --replace, as image.sh does
  "image.sh pull")
    [ -d "$STORE/$2" ] || exit 3
    mkdir -p "$3" && cp -R "$STORE/$2/." "$3/" ;;
  "image.sh push")
    if [ "$2" = --replace ]; then rm -rf "${STORE:?}/$3"; set -- push "$3" "$4"
    # STUB_RACE=<key>: another run pushes its own image under <key> just before this push
    elif [ "$2" = "${STUB_RACE:-}" ]; then
      mkdir -p "$STORE/$2"; echo theirs > "$STORE/$2/box_0.img"
      echo eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee > "$STORE/$2/image-id"; echo ffffffffffffffffffffffffffffffff > "$STORE/$2/backing-id"
    fi
    [ ! -d "$STORE/$2" ] || { echo "image.sh: already cached under $2; not pushing"; exit 4; }
    mkdir -p "$STORE/$2" && cp -R "$3/." "$STORE/$2/" ;;
  "build.sh "*) mkdir -p "$2" && echo base > "$2/box_0.img" ;;
  # as the real layer.sh does: refuse a layer dir that is not empty, and bind the layer to its base
  "layer.sh "*)
    [ -z "$(ls -A "$2" 2>/dev/null)" ] || { echo "layer.sh: $2 is not empty" >&2; exit 2; }
    [ -s "$1/image-id" ] || exit 1
    mkdir -p "$2" && echo layer > "$2/box_0.img" && newid > "$2/image-id" && cp "$1/image-id" "$2/backing-id" ;;
  "snapshot.sh "*)
    mkdir -p "$2" && echo prepared > "$2/box_0.img" && newid > "$2/image-id" && cp "$1/image-id" "$2/backing-id" ;;
  # what is in data-dir when room is checked
  "space.sh "*)
    { printf '%s:' "$1"; for d in box layer prepared; do [ ! -e "$MVM_DATA_DIR/$d/box_0.img" ] || printf ' %s' "$d"; done; echo; } >> "$ROOM" ;;
  # boots only a whole chain: each delta's backing-id is the image-id of the image under it
  "boot.sh "*)
    data="$(dirname "$1")"
    case "$(basename "$1")" in prepared) chain="prepared layer box" ;; layer) chain="layer box" ;; *) echo "boot.sh: not a layer or prepared dir: $1"; exit 1 ;; esac
    up=""
    for d in $chain; do
      [ -s "$data/$d/image-id" ] || { echo "boot.sh: $d has no image-id"; exit 1; }
      if [ -n "$up" ] && [ "$(cat "$data/$up/backing-id")" != "$(cat "$data/$d/image-id")" ]; then
        echo "boot.sh: $up is not over this $d"; exit 1
      fi
      up="$d"
    done ;;
  "run.sh "*) grep -q fail "$1" && exit 7; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$S/stub"
    for f in key.sh image.sh build.sh layer.sh boot.sh sync.sh run.sh shell-wrapper.sh space.sh snapshot.sh; do
        cp "$S/stub" "$S/$f"
    done
    export PATH="$REPO/tests/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    export MVM_IMAGE_KEY='AGE-SECRET-KEY-1MAINTESTKEY'
    export MVM_DATA_DIR="$BATS_TEST_TMPDIR/data" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
    export MVM_DISABLE_CACHE=false MVM_CACHE_AFTER_PREPARE=false MVM_SYNC_TIME=false
    export MVM_PREPARE='echo prep' MVM_RUN='echo run'
    : > "$GITHUB_OUTPUT"
    # the store holds a base and the layer made over it; no prepared image
    seed base; seed layer
}

K=1111111111111111111111111111111111111111111111111111111111111111
L=2222222222222222222222222222222222222222222222222222222222222222
P=3333333333333333333333333333333333333333333333333333333333333333
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb C=cccccccccccccccccccccccccccccccc
dir_of() { case "$1" in base) echo "$STORE/$K" ;; layer) echo "$STORE/$L" ;; prepared) echo "$STORE/$P" ;; esac; }
# a cached image: base (image-id A), layer (B, over A), prepared (C, over B)
seed() {
    d="$(dir_of "$1")"; mkdir -p "$d"; echo "$1" > "$d/box_0.img"
    case "$1" in
        base) echo $A > "$d/image-id" ;;
        layer) echo $B > "$d/image-id"; echo $A > "$d/backing-id" ;;
        prepared) echo $C > "$d/image-id"; echo $B > "$d/backing-id" ;;
    esac
}
drop() { for i in "$@"; do rm -rf "$(dir_of "$i")"; done; }
id() { cat "$(dir_of "$1")/$2"; }

main() { bash "$S/main.sh"; }
order() { grep -oE '^[a-z-]+\.sh( (pull|push|in|out|hit|miss|layer|prepare|--install|--recipe|--prepared|--layer|--base))?' "$CALLS" | paste -sd' '; }
called() { grep -qxF -- "$1" "$CALLS" || { echo "not called: $1"; cat "$CALLS"; false; }; }
pushes() { grep '^image.sh push' "$CALLS" | sed "s|$MVM_DATA_DIR/||" | paste -sd' '; }
boots() { grep '^boot.sh' "$CALLS" | sed "s|$MVM_DATA_DIR/||" | paste -sd' '; }
# the layer in the store is over the base in the store, and the prepared (if any) over the layer
bound() {
    [ "$(id layer backing-id)" = "$(id base image-id)" ] || { echo "layer not over base"; false; }
    [ ! -d "$(dir_of prepared)" ] || [ "$(id prepared backing-id)" = "$(id layer image-id)" ] || { echo "prepared not over layer"; false; }
}

HIT="key.sh --recipe key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out"
REBUILD_ALL="key.sh --recipe key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull space.sh miss build.sh image.sh push space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out"
REBUILD_LAYER="key.sh --recipe key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out"
PREPARED_HIT="key.sh --recipe key.sh --prepared key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh sync.sh out"
PREPARE_AGAIN="key.sh --recipe key.sh --prepared key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull image.sh pull boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out"

@test "a layer hit: room for a hit, pull the layer and its base, boot the layer -- no build, no push" {
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$HIT" ]
    D="$MVM_DATA_DIR"
    called "image.sh pull $L $D/layer"
    called "image.sh pull $K $D/box"
    [ "$(boots)" = "boot.sh layer" ]
}

# spec: tests/safety.bats -- install-tools.sh found no hfsplus for the plugin's media microVM
#       (MVM_NO_HFSPLUS): a run that must build the base image stops there, naming why, before it
#       makes room or builds anything; a run that pulls its base, or builds only the layer over
#       it, needs no hfsplus and goes on
@test "with no hfsplus on the runner, a base miss stops before the build, naming why, and a hit goes on" {
    export MVM_NO_HFSPLUS=6.17.0-1022-azure
    drop layer
    run main
    [ "$status" -eq 0 ] || { echo "layer miss over a base hit: $output"; false; }
    [ "$(order)" = "$REBUILD_LAYER" ]
    seed layer; drop base; : > "$CALLS"
    run main
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"::error title=mavericks-vm::building the base image needs the hfsplus module for the plugin's media microVM, and install-tools.sh found none for the running kernel, 6.17.0-1022-azure (its warning says why); booting another kernel takes a packer-plugin-macosx release with privops' kernel choice (chooseRelease), which the pinned one is not"* ]] || { echo "$output"; false; }
    [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$output"; false; }
    ! grep -E '^(build\.sh|space\.sh miss)' "$CALLS" || false
}

@test "a layer miss with a base hit: build the layer over the pulled base, push it, boot it" {
    drop layer
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$REBUILD_LAYER" ]
    called "layer.sh $MVM_DATA_DIR/box $MVM_DATA_DIR/layer"
    [ "$(pushes)" = "image.sh push $L layer" ]
    [ "$(boots)" = "boot.sh layer" ]
    bound
}

@test "a layer miss with a base miss: build and push the base, then the layer, boot the layer" {
    drop layer base
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$REBUILD_ALL" ]
    [ "$(pushes)" = "image.sh push $K box image.sh push $L layer" ]
    [ "$(boots)" = "boot.sh layer" ]
    bound
}

# spec: the layer is a delta over the bytes of the base; a layer whose base is gone is thrown away
#       (before the base's build counts the room), built again over the new base, and pushed in
#       place of the stale one
@test "a layer hit with a base miss: the layer is thrown away first, rebuilt over the new base, and replaced" {
    drop base
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$REBUILD_ALL" ]
    [ "$(pushes)" = "image.sh push $K box image.sh push --replace $L layer" ]
    [ "$(boots)" = "boot.sh layer" ]
    grep -qx 'miss:' "$ROOM" || { cat "$ROOM"; false; }
    bound
}

# spec: push-if-absent kept the stale layer under its key, beside the new base, so every later run
#       booted a delta over the wrong bytes (task 3 review, Important 1)
@test "a layer hit with a base miss: the next run boots a layer bound to the base, building nothing" {
    drop base
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    : > "$CALLS"
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$HIT" ]
    bound
}

@test "a base pulled with no image-id is a base miss: base and layer are built and replaced" {
    rm "$(dir_of base)/image-id"
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$REBUILD_ALL" ]
    [ "$(pushes)" = "image.sh push --replace $K box image.sh push --replace $L layer" ]
    grep -qx 'miss:' "$ROOM" || { cat "$ROOM"; false; }
    bound
}

@test "a layer made over a different base is rebuilt over this one and replaced" {
    echo dddddddddddddddddddddddddddddddd > "$(dir_of layer)/backing-id"
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$REBUILD_LAYER" ]
    [ "$(pushes)" = "image.sh push --replace $L layer" ]
    grep -qx 'layer: box' "$ROOM" || { cat "$ROOM"; false; }
    bound
}

@test "a layer with no backing-id is rebuilt over this base and replaced" {
    rm "$(dir_of layer)/backing-id"
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$REBUILD_LAYER" ]
    [ "$(pushes)" = "image.sh push --replace $L layer" ]
    bound
}

# spec: when another run cached its own base first, this run's push is skipped (exit 4), and the
#       layer made over this run's base is bound to an image that is not in the store; it is not
#       cached (task 3 re-review, minor 1). This run still boots its own whole chain.
@test "a base push another run beat: the layer made over this run's base is not cached" {
    drop base layer
    STUB_RACE=$K MVM_STORE=file run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --recipe key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull space.sh miss build.sh image.sh push space.sh layer layer.sh boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    [ "$(pushes)" = "image.sh push $K box" ]
    [ "$(boots)" = "boot.sh layer" ]
    [ ! -d "$(dir_of layer)" ]
    run grep -q '^cache-save-' "$GITHUB_OUTPUT"
    [ "$status" -ne 0 ]
}

# spec: a stale layer is pushed with --replace, which never skips; over a base this run could not
#       cache, it would overwrite a layer another run made over the cached base
@test "a base push another run beat: a stale layer is not replaced with one made over this run's base" {
    drop base
    STUB_RACE=$K run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(pushes)" = "image.sh push $K box" ]
    [ "$(id layer image-id)" = "$B" ]
}

@test "a layer push another run beat: the prepared image made over this run's layer is not cached" {
    drop layer
    STUB_RACE=$L MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --recipe key.sh --prepared key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull image.sh pull space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh boot.sh sync.sh in run.sh sync.sh out" ]
    [ "$(pushes)" = "image.sh push $L layer" ]
    [ "$(boots)" = "boot.sh layer boot.sh prepared" ]
    [ ! -d "$(dir_of prepared)" ]
}

@test "a pull that errs (not a miss) fails the step and builds nothing" {
    STUB_FAIL='image.sh pull *' run main
    [ "$status" -ne 0 ]
    run grep -qE '^(build|layer)\.sh' "$CALLS"
    [ "$status" -ne 0 ]
}

@test "disable-cache builds the base and the layer, boots the layer, and neither pulls nor pushes" {
    MVM_DISABLE_CACHE=true MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "space.sh miss build.sh space.sh layer layer.sh boot.sh shell-wrapper.sh --install sync.sh in run.sh run.sh sync.sh out" ]
    [ "$(boots)" = "boot.sh layer" ]
}

@test "run's status is the step's, and the workspace still comes back" {
    MVM_RUN='fail now' run main
    [ "$status" -eq 7 ]
    grep -q '^sync.sh out' "$CALLS"
}

@test "a failing prepare stops the step before run" {
    MVM_PREPARE='fail now' run main
    [ "$status" -eq 7 ]
    [ "$(grep -c '^run.sh' "$CALLS")" = 1 ]
}

@test "a prepared hit: pull it, its layer and their base, boot the prepared guest, skip prepare, say so" {
    seed prepared
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$PREPARED_HIT" ]
    D="$MVM_DATA_DIR"
    called "image.sh pull $P $D/prepared"
    called "image.sh pull $L $D/layer"
    called "image.sh pull $K $D/box"
    [ "$(boots)" = "boot.sh prepared" ]
    grep -qxF 'cache-after-prepare-hit=true' "$GITHUB_OUTPUT"
}

@test "a prepared miss with a layer hit: boot the layer, prepare, snapshot over it, push, boot the prepared" {
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$PREPARE_AGAIN" ]
    [ "$(boots)" = "boot.sh layer boot.sh prepared" ]
    called "snapshot.sh $MVM_DATA_DIR/layer $MVM_DATA_DIR/prepared"
    [ "$(pushes)" = "image.sh push $P prepared" ]
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
    bound
}

# spec: the prepared image is a delta over the layer: over a layer built again here it is stale,
#       so it is thrown away (before any build counts the room), prepared again, and replaced
@test "a prepared hit whose layer misses: the prepared is thrown away, the layer built, prepare runs again" {
    seed prepared; drop layer
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --recipe key.sh --prepared key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull image.sh pull space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out" ]
    [ "$(boots)" = "boot.sh layer boot.sh prepared" ]
    [ "$(pushes)" = "image.sh push $L layer image.sh push --replace $P prepared" ]
    grep -qx 'layer: box' "$ROOM" || { cat "$ROOM"; false; }
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
    bound
}

@test "a prepared hit and a layer hit whose base misses: base, layer and prepared are all made again" {
    seed prepared; drop base
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "key.sh --recipe key.sh --prepared key.sh --layer key.sh --base space.sh hit image.sh pull image.sh pull image.sh pull space.sh miss build.sh image.sh push space.sh layer layer.sh image.sh push boot.sh shell-wrapper.sh --install sync.sh in run.sh space.sh prepare snapshot.sh image.sh push boot.sh sync.sh in run.sh sync.sh out" ]
    [ "$(boots)" = "boot.sh layer boot.sh prepared" ]
    [ "$(pushes)" = "image.sh push $K box image.sh push --replace $L layer image.sh push --replace $P prepared" ]
    grep -qx 'miss:' "$ROOM" || { cat "$ROOM"; false; }
    bound
}

@test "a prepared image made over a different layer is prepared again and replaced" {
    seed prepared; echo dddddddddddddddddddddddddddddddd > "$(dir_of prepared)/backing-id"
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$PREPARE_AGAIN" ]
    [ "$(pushes)" = "image.sh push --replace $P prepared" ]
    grep -qxF 'cache-after-prepare-hit=false' "$GITHUB_OUTPUT"
    bound
}

@test "a prepared image with no backing-id is prepared again and replaced, and the next run is a hit" {
    seed prepared; rm "$(dir_of prepared)/backing-id"
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$PREPARE_AGAIN" ]
    [ "$(pushes)" = "image.sh push --replace $P prepared" ]
    bound
    : > "$CALLS"
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(order)" = "$PREPARED_HIT" ]
}

# spec: every failure names the image (base, layer or prepared) and the step that failed, even
#       when the step itself fails without a word
@test "a failing step names its image and itself" {
    while IFS='|' read -r env drops fail want; do
        rm -rf "$STORE"; seed base; seed layer; drop $drops; : > "$CALLS"
        run env $env STUB_FAIL="$fail" bash "$S/main.sh"
        [ "$status" -ne 0 ] || { echo "$fail: status 0"; false; }
        [[ "$output" == *"::error title=mavericks-vm::$want failed"* ]] || { echo "$fail: $output"; false; }
    done <<'TABLE'
MVM_CACHE_AFTER_PREPARE=false||key.sh --recipe|fetching the base recipe
MVM_CACHE_AFTER_PREPARE=false||key.sh --layer|computing the layer image's key
MVM_CACHE_AFTER_PREPARE=false||key.sh --base|computing the base image's key
MVM_CACHE_AFTER_PREPARE=true||key.sh --prepared|computing the prepared image's key
MVM_CACHE_AFTER_PREPARE=true||image.sh pull 3*|pulling the prepared image
MVM_CACHE_AFTER_PREPARE=false||image.sh pull 2*|pulling the layer image
MVM_CACHE_AFTER_PREPARE=false||image.sh pull 1*|pulling the base image
MVM_CACHE_AFTER_PREPARE=false|base|build.sh *|building the base image
STUB_FAIL_STATUS=2|layer|layer.sh *|building the layer image
MVM_CACHE_AFTER_PREPARE=false|base|image.sh push 1*|pushing the base image
MVM_CACHE_AFTER_PREPARE=false|layer|image.sh push 2*|pushing the layer image
MVM_CACHE_AFTER_PREPARE=true||image.sh push 3*|pushing the prepared image
TABLE
}

# spec: one ::error per failure (task 3 review): space.sh, layer.sh (when it exits 1), boot.sh and
#       snapshot.sh name the image and the step themselves, so main.sh adds nothing
@test "a step that names its own failure is named once" {
    while IFS='|' read -r env drops fail; do
        rm -rf "$STORE"; seed base; seed layer; drop $drops; : > "$CALLS"
        run env $env STUB_FAIL="$fail" STUB_SAY='::error title=mavericks-vm::the step named it' bash "$S/main.sh"
        [ "$status" -ne 0 ] || { echo "$fail: status 0"; false; }
        [ "$(grep -c '::error' <<< "$output")" -eq 1 ] || { echo "$fail: $output"; false; }
    done <<'TABLE'
MVM_CACHE_AFTER_PREPARE=false||space.sh hit
MVM_CACHE_AFTER_PREPARE=false|base|space.sh miss
MVM_CACHE_AFTER_PREPARE=false|layer|space.sh layer
MVM_CACHE_AFTER_PREPARE=true||space.sh prepare
MVM_CACHE_AFTER_PREPARE=false|layer|layer.sh *
MVM_CACHE_AFTER_PREPARE=false||boot.sh */layer
MVM_CACHE_AFTER_PREPARE=true||snapshot.sh *
MVM_CACHE_AFTER_PREPARE=true||boot.sh */prepared
TABLE
}

@test "with no prepare, only run runs" {
    MVM_PREPARE= run main
    [ "$(grep -c '^run.sh' "$CALLS")" = 1 ]
}

# spec: the repo tier keeps two cache entries, so a change that moves only the layer saves only the
#       small ones: one per image (cache-save-base, -layer, -prepared). Each is written after a
#       push that stored that image; a push that was skipped writes nothing
saved() {  # $@ = the outputs that must be there, and no others of cache-save-*
    for o in base layer prepared; do
        if [[ " $* " == *" $o "* ]]; then grep -qxF "cache-save-$o=true" "$GITHUB_OUTPUT" || { echo "no cache-save-$o"; cat "$GITHUB_OUTPUT"; false; }
        else ! grep -q "^cache-save-$o=" "$GITHUB_OUTPUT" || { echo "cache-save-$o"; false; }
        fi
    done
}

@test "repo store, base and layer miss: both are to be saved, and no prepared" {
    drop base layer
    MVM_STORE=file run main
    [ "$status" -eq 0 ]
    saved base layer
}

@test "repo store, layer miss over a base hit: only the layer is to be saved, never the base" {
    drop layer
    MVM_STORE=file run main
    [ "$status" -eq 0 ]
    [ "$(pushes)" = "image.sh push $L layer" ]
    saved layer
}

@test "repo store, hit: nothing new to save" {
    MVM_STORE=file run main
    [ "$status" -eq 0 ]
    saved
}

# spec: the repo tier once skipped the base's push with cache-after-prepare on, keeping only the
#       prepared guest; the prepared is now a delta over the layer, over the base, so every image
#       this run builds is pushed and named
@test "repo store, cache-after-prepare miss: base, layer and prepared are each pushed, all three saved" {
    drop base layer
    MVM_STORE=file MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(pushes)" = "image.sh push $K box image.sh push $L layer image.sh push $P prepared" ]
    saved base layer prepared
}

@test "repo store, prepare changed and nothing else: only the prepared image is to be saved, the layer kept" {
    MVM_STORE=file MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(pushes)" = "image.sh push $P prepared" ]
    saved prepared
}

@test "a failing run still reports what it cached, so it is saved anyway" {
    drop base layer
    MVM_STORE=file MVM_RUN='fail' run main
    [ "$status" -eq 7 ]
    saved base layer
}

# spec: a 40-minute base is not thrown away because the layer built over it failed
@test "repo store: a base built before a failed layer build is still reported, so it is saved" {
    drop base layer
    MVM_STORE=file STUB_FAIL='layer.sh *' run main
    [ "$status" -ne 0 ]
    [ "$(pushes)" = "image.sh push $K box" ]
    saved base
}

@test "repo store: every push skipped because another run cached the key first names nothing to save" {
    drop base layer
    MVM_STORE=file STUB_RACE=$K run main
    [ "$status" -eq 0 ]
    saved
}

@test "repo store: a layer push another run beat saves nothing" {
    drop layer
    MVM_STORE=file STUB_RACE=$L run main
    [ "$status" -eq 0 ]
    saved
}

# spec: the base recipe is fetched once, and passed to every key.sh after it, which would otherwise
#       fetch it again
@test "the base recipe is fetched once and handed to the key computations" {
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(grep -c 'key.sh --recipe' "$CALLS")" = 1 ]
    [ "$(sort -u "$BATS_TEST_TMPDIR/recipe-seen")" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/recipe-seen")" = 3 ]
}

# spec: only this run's set is kept in the blob dir, so what the restore brought back that is no
#       longer in the set (an old layer, an old prepared) is neither kept on disk nor saved; it is
#       pruned as soon as the keys are known, before any pull or build, and only <64-hex>.tar.zst.age
#       files are candidates
prune_setup() {
    export MVM_STORE=file MVM_BLOB_DIR="$BATS_TEST_TMPDIR/blob"
    mkdir -p "$MVM_BLOB_DIR"
    OLD1=$(printf '%64s' | tr ' ' d) OLD2=$(printf '%64s' | tr ' ' e)
    for k in $K $L $OLD1 $OLD2; do echo x > "$MVM_BLOB_DIR/$k.tar.zst.age"; done
    echo x > "$MVM_BLOB_DIR/notes.txt"; echo x > "$MVM_BLOB_DIR/${OLD1}0.tar.zst.age"; echo x > "$MVM_BLOB_DIR/${OLD1:1}.tar.zst.age"
}
@test "repo store: blobs that are none of this run's keys are deleted; this run's, and other files, are left" {
    prune_setup
    run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -e "$MVM_BLOB_DIR/$K.tar.zst.age" ]
    [ -e "$MVM_BLOB_DIR/$L.tar.zst.age" ]
    [ ! -e "$MVM_BLOB_DIR/$OLD1.tar.zst.age" ]
    [ ! -e "$MVM_BLOB_DIR/$OLD2.tar.zst.age" ]
    [ -e "$MVM_BLOB_DIR/notes.txt" ]
    [ -e "$MVM_BLOB_DIR/${OLD1}0.tar.zst.age" ]
    [ -e "$MVM_BLOB_DIR/${OLD1:1}.tar.zst.age" ]
}

@test "repo store: the prepared key is in the set when cache-after-prepare is on" {
    prune_setup
    echo x > "$MVM_BLOB_DIR/$P.tar.zst.age"
    MVM_CACHE_AFTER_PREPARE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -e "$MVM_BLOB_DIR/$P.tar.zst.age" ]
    [ ! -e "$MVM_BLOB_DIR/$OLD1.tar.zst.age" ]
}

@test "repo store: a stale blob is gone before the first pull, even when the run then fails" {
    prune_setup
    STUB_FAIL='image.sh pull *' STUB_FAIL_STATUS=9 run main
    [ "$status" -ne 0 ]
    [ ! -e "$MVM_BLOB_DIR/$OLD1.tar.zst.age" ]
}

@test "the registry store and disable-cache prune nothing" {
    prune_setup
    MVM_STORE=registry run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -e "$MVM_BLOB_DIR/$OLD1.tar.zst.age" ]
    MVM_DISABLE_CACHE=true run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -e "$MVM_BLOB_DIR/$OLD1.tar.zst.age" ]
}

# spec: on a miss the key was first parsed after the 40-minute build, at the push; a recipient or a
#       passphrase saved as the secret fails at once instead, before anything is pulled or built
#       (final review, I4)
@test "an image-key that is not an age identity fails at once, before any pull or build" {
    MVM_IMAGE_KEY='age1thisisarecipientnotanidentity' run main
    [ "$status" -ne 0 ]
    [[ "$output" == *"image-key"* ]] || false
    [[ "$output" == *"AGE-SECRET-KEY-1"* ]] || false
    [ ! -s "$CALLS" ]
}

# spec: with cache-after-prepare on and prepare empty, the repo store once kept nothing, so every
#       run built for 40 minutes (final review, I3); with no prepare the prepared guest is the
#       layer guest, so the base and the layer are cached, and nothing under a prepared key
@test "cache-after-prepare with an empty prepare caches the base and the layer, and no prepared image" {
    drop base layer
    MVM_STORE=file MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='' run main
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(pushes)" = "image.sh push $K box image.sh push $L layer" ]
    saved base layer
    run grep -q 'key.sh --prepared' "$CALLS"
    [ "$status" -ne 0 ]
}

# spec: action.yml -- the repo tier keeps one cache entry per image: the base (one ~6 GB blob), the
#       layer and the prepared image, each saved only when this run stored it, so a change that
#       moves only the layer, or only prepare, never saves the base (or the layer) again
# (an actions/cache step is counted only when it holds a guest image, in MVM_BLOB_DIR: the apt
# packages' cache has its own test, in tests/safety.bats)
action_step() {  # $1 = a step's id or the start of its uses, $2 = which of them (1st, 2nd, ...); writes it as JSON to step.json
    python3 - "$REPO/action.yml" "$1" "${2:-1}" > "$BATS_TEST_TMPDIR/step.json" <<'PY'
import sys, yaml, json
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
image = lambda s: not s.get("uses", "").startswith("actions/cache/") or "MVM_BLOB_DIR" in s.get("with", {}).get("path", "")
m = [s for s in steps if image(s) and (s.get("id") == sys.argv[2] or s.get("uses", "").startswith(sys.argv[2]))]
print(json.dumps(m[int(sys.argv[3]) - 1]))
PY
}
field() {
    python3 -c 'import sys, json; d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]: d = d[k]
print(d)' "$BATS_TEST_TMPDIR/step.json" "$@"
}
key_step() {  # runs the key step, taken from step.json, in a scratch action dir; sets $status, $output
    field run > "$BATS_TEST_TMPDIR/keystep.sh"
    mkdir -p "$BATS_TEST_TMPDIR/action/scripts"; cp "$S/key.sh" "$BATS_TEST_TMPDIR/action/scripts/"
    : > "$GITHUB_OUTPUT"; : > "$BATS_TEST_TMPDIR/env"; : > "$CALLS"; : > "$BATS_TEST_TMPDIR/recipe-seen"
    GITHUB_ACTION_PATH="$BATS_TEST_TMPDIR/action" GITHUB_ENV="$BATS_TEST_TMPDIR/env" \
        run bash -e "$BATS_TEST_TMPDIR/keystep.sh"
}
KEY_IF="env.MVM_STORE == 'file' && env.MVM_DISABLE_CACHE != 'true'"
RUN='${{ github.run_id }}-${{ github.run_attempt }}'
RECIPE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

@test "action.yml's key step outputs base, layer and recipe, and prepared only when it is wanted" {
    action_step key
    MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='' key_step
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "base=$K" "$GITHUB_OUTPUT" || false
    grep -qxF "layer=$L" "$GITHUB_OUTPUT" || false
    grep -qxF "prepared=" "$GITHUB_OUTPUT" || false
    MVM_CACHE_AFTER_PREPARE=false MVM_PREPARE='echo p' key_step
    grep -qxF "prepared=" "$GITHUB_OUTPUT" || false
    MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='echo p' key_step
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qxF "prepared=$P" "$GITHUB_OUTPUT" || false
    grep -qxF "recipe=$RECIPE" "$GITHUB_OUTPUT" || false
}

# spec: a recipe left in the job's environment would be trusted by a later mavericks-vm step of
#       another version, which would compute its keys from this one's recipe
@test "action.yml's key step fetches the recipe once, hands it to its keys, and never writes it to the job's environment" {
    action_step key
    [ "$(field env MVM_BASE_RECIPE)" = "" ]
    MVM_CACHE_AFTER_PREPARE=true MVM_PREPARE='echo p' MVM_BASE_RECIPE=leaked key_step
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(grep -c 'key.sh --recipe' "$CALLS")" = 1 ]
    [ "$(sort -u "$BATS_TEST_TMPDIR/recipe-seen")" = $RECIPE ]
    [ ! -s "$BATS_TEST_TMPDIR/env" ]
    ! field run | grep -q GITHUB_ENV || false
}

@test "action.yml's main step takes the recipe from the key step, which is empty when no key step ran" {
    action_step main
    [ "$(field env MVM_BASE_RECIPE)" = '${{ steps.key.outputs.recipe }}' ]
}

@test "action.yml's key step names its own failure" {
    action_step key
    for f in 'key.sh --recipe' 'key.sh --layer' 'key.sh --base'; do
        STUB_FAIL="$f" STUB_SAY='key.sh: it broke' key_step
        [ "$status" -ne 0 ] || { echo "$f: status 0"; false; }
        [[ "$output" == *"::error title=mavericks-vm::computing the cache keys failed"* ]] || { echo "$f: $output"; false; }
    done
}

@test "action.yml's key step does not run when the cache is disabled or the store is not the repo's" {
    action_step key
    [ "$(field if)" = "$KEY_IF" ]
}

@test "action.yml's restores: each image's blob alone, by its key, else its key's prefix; prepared only when wanted" {
    n=0
    for img in base layer prepared; do
        n=$((n + 1))
        action_step actions/cache/restore $n
        if [ $img = prepared ]; then [ "$(field if)" = "$KEY_IF && steps.key.outputs.prepared != ''" ]
        else [ "$(field if)" = "$KEY_IF" ]; fi
        [ "$(field with path)" = "\${{ env.MVM_BLOB_DIR }}/\${{ steps.key.outputs.$img }}.tar.zst.age" ]
        [ "$(field with key)" = "mavericks-vm-$img-\${{ steps.key.outputs.$img }}" ]
        [ "$(field with restore-keys)" = "mavericks-vm-$img-\${{ steps.key.outputs.$img }}-" ]
    done
    run python3 -c 'import yaml; print(sum(s.get("uses", "").startswith("actions/cache/restore") and "MVM_BLOB_DIR" in s["with"]["path"] for s in yaml.safe_load(open("'"$REPO"'/action.yml"))["runs"]["steps"]))'
    [ "$output" = 3 ]
}

@test "action.yml's saves: each image's blob alone, under its key and the run, only when this run stored that image" {
    n=0
    for img in base layer prepared; do
        n=$((n + 1))
        action_step actions/cache/save $n
        if [ $img = prepared ]; then [ "$(field if)" = "always() && steps.main.outputs.cache-save-$img == 'true' && steps.key.outputs.prepared != ''" ]
        else [ "$(field if)" = "always() && steps.main.outputs.cache-save-$img == 'true'" ]; fi
        [ "$(field with path)" = "\${{ env.MVM_BLOB_DIR }}/\${{ steps.key.outputs.$img }}.tar.zst.age" ]
        [ "$(field with key)" = "mavericks-vm-$img-\${{ steps.key.outputs.$img }}-$RUN" ]
    done
    run python3 -c 'import yaml; print(sum(s.get("uses", "").startswith("actions/cache/save") and "MVM_BLOB_DIR" in s["with"]["path"] for s in yaml.safe_load(open("'"$REPO"'/action.yml"))["runs"]["steps"]))'
    [ "$output" = 3 ]
}

# spec: tests/build.bats -- build.sh takes the template first; a bare <dir> exits 2 and breaks the action
@test "a miss and a disabled cache both build with build.sh mavericks <box-dir>" {
    drop base layer
    run main
    [ "$status" -eq 0 ]
    grep -qE '^build\.sh mavericks [^ ]+/box$' "$CALLS" || { cat "$CALLS"; false; }
    : > "$CALLS"
    MVM_DISABLE_CACHE=true run main
    [ "$status" -eq 0 ]
    grep -qE '^build\.sh mavericks [^ ]+/box$' "$CALLS" || { cat "$CALLS"; false; }
}
