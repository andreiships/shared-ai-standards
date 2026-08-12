#!/usr/bin/env bats

setup() {
  export ACTION_ROOT="$BATS_TEST_DIRNAME/.."
  export TEST_ROOT="$BATS_TEST_TMPDIR/root"
  export GITHUB_WORKSPACE="$TEST_ROOT/workspace"
  export HOME="$TEST_ROOT/home"
  export GITHUB_OUTPUT="$TEST_ROOT/github-output"
  export CACHE_API="https://cache.invalid"
  export CACHE_KEY="pistachiorama/tool/linux/x64/v1"
  mkdir -p "$GITHUB_WORKSPACE" "$HOME" "$TEST_ROOT/bin"
  : > "$GITHUB_OUTPUT"
}

make_archive() {
  local member_kind="$1"
  local archive="$2"
  python3 - "$member_kind" "$archive" <<'PY'
import io
import sys
import tarfile

kind, archive = sys.argv[1:]
with tarfile.open(archive, "w:gz") as tar:
    if kind == "valid":
        payload = b"safe executable\n"
        info = tarfile.TarInfo("home/.cargo/bin/worker-build")
        info.mode = 0o755
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))
    elif kind == "traversal":
        payload = b"escaped\n"
        info = tarfile.TarInfo("workspace/../../escaped")
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))
    elif kind == "symlink":
        info = tarfile.TarInfo("home/.cargo/bin/worker-build")
        info.type = tarfile.SYMTYPE
        info.linkname = "/tmp/escaped"
        tar.addfile(info)
PY
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

@test "restore maps a validated home member beneath HOME" {
  [ -f "$ACTION_ROOT/cache-v2-archive.py" ]
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.cargo/bin/worker-build")" = "safe executable" ]
  [ -x "$HOME/.cargo/bin/worker-build" ]
}

@test "restore rejects parent traversal before writing outside a safe root" {
  [ -f "$ACTION_ROOT/cache-v2-archive.py" ]
  archive="$TEST_ROOT/traversal.tar.gz"
  make_archive traversal "$archive"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe archive member"* ]]
  [ ! -e "$TEST_ROOT/escaped" ]
}

@test "restore rejects symlinks" {
  [ -f "$ACTION_ROOT/cache-v2-archive.py" ]
  archive="$TEST_ROOT/symlink.tar.gz"
  make_archive symlink "$archive"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported archive member type"* ]]
  [ ! -e "$HOME/.cargo/bin/worker-build" ]
}

@test "pack rejects a source tree containing a symlink" {
  [ -f "$ACTION_ROOT/cache-v2-archive.py" ]
  mkdir -p "$HOME/.cargo/bin"
  ln -s /tmp "$HOME/.cargo/bin/unsafe-link"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" pack \
    --archive "$TEST_ROOT/cache.tar.gz" --workspace "$GITHUB_WORKSPACE" \
    --home "$HOME" --path "$HOME/.cargo/bin"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported source type"* ]]
  [ ! -e "$TEST_ROOT/cache.tar.gz" ]
}

@test "restore refuses a checksum mismatch before extraction" {
  [ -f "$ACTION_ROOT/cache-v2.sh" ]
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"
  cp "$archive" "$TEST_ROOT/download.tar.gz"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --head "* ]]; then
  printf '200'
  exit 0
fi
output=''
headers=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$TEST_ROOT/download.tar.gz" "$output"
printf 'HTTP/1.1 200 OK\r\nX-Cache-SHA256: %064d\r\n\r\n' 0 > "$headers"
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"
  export CACHE_TOKEN="read-token-placeholder"
  export ACTION_PATH="$ACTION_ROOT"

  run bash "$ACTION_ROOT/cache-v2.sh" restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.cargo/bin/worker-build" ]
}

@test "save uploads the computed digest and treats HTTP 409 as a conflict" {
  [ -f "$ACTION_ROOT/cache-v2.sh" ]
  mkdir -p "$HOME/.cargo/bin"
  printf '#!/bin/sh\n' > "$HOME/.cargo/bin/worker-build"
  chmod +x "$HOME/.cargo/bin/worker-build"
  export CACHE_PATH="$HOME/.cargo/bin/worker-build"
  export CACHE_TOKEN="write-token-placeholder"
  export ACTION_PATH="$ACTION_ROOT"
  export CURL_ARGS_LOG="$TEST_ROOT/curl-args"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS_LOG"
printf '409'
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"

  run bash "$ACTION_ROOT/cache-v2.sh" save

  [ "$status" -ne 0 ]
  [[ "$output" == *"immutable key conflict"* ]]
  grep -Eq '^X-Cache-SHA256: [0-9a-f]{64}$' "$CURL_ARGS_LOG"
  grep -Fxq 'If-None-Match: *' "$CURL_ARGS_LOG"
}

@test "composite exposes additive v2 inputs and dispatches to scripts" {
  action="$ACTION_ROOT/action.yml"

  grep -q '^  api-version:' "$action"
  grep -q '^  read-token:' "$action"
  grep -q '^  write-token:' "$action"
  grep -q 'cache-v2.sh.*restore' "$action"
  grep -q 'cache-v2.sh.*save' "$action"
}
