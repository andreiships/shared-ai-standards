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
    elif kind == "duplicate":
        for name, payload in (
            ("home/.cargo/bin/worker-build", b"first\n"),
            ("home/.cargo/bin//worker-build", b"second\n"),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
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

@test "archive client fails closed without race-safe platform primitives" {
  run python3 - "$ACTION_ROOT/cache-v2-archive.py" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("cache_v2_archive", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
del os.O_NOFOLLOW
try:
    module._require_safe_platform()
except module.CacheArchiveError as error:
    print(error)
    raise SystemExit(0)
raise SystemExit(1)
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"platform lacks race-safe archive primitives"* ]]
  [[ "$output" == *"O_NOFOLLOW"* ]]
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

@test "pack rejects a hardlinked source that aliases an outside-root file" {
  mkdir -p "$HOME/.cargo/bin"
  printf 'outside material\n' > "$TEST_ROOT/outside-source"
  ln "$TEST_ROOT/outside-source" "$HOME/.cargo/bin/worker-build"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" pack \
    --archive "$TEST_ROOT/cache.tar.gz" --workspace "$GITHUB_WORKSPACE" \
    --home "$HOME" --path "$HOME/.cargo/bin/worker-build"

  [ "$status" -ne 0 ]
  [[ "$output" == *"hardlinked source file"* ]]
  [ ! -e "$TEST_ROOT/cache.tar.gz" ]
}

@test "pack and restore round-trip workspace and home paths" {
  mkdir -p "$GITHUB_WORKSPACE/build" "$HOME/.cargo/bin"
  printf 'workspace artifact\n' > "$GITHUB_WORKSPACE/build/output.wasm"
  printf '#!/bin/sh\n' > "$HOME/.cargo/bin/worker-build"
  chmod +x "$HOME/.cargo/bin/worker-build"
  archive="$TEST_ROOT/roundtrip.tar.gz"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" pack \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME" \
    --path "$GITHUB_WORKSPACE/build" --path "$HOME/.cargo/bin/worker-build"
  [ "$status" -eq 0 ]

  rm -rf "$GITHUB_WORKSPACE/build" "$HOME/.cargo"
  run python3 "$ACTION_ROOT/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_WORKSPACE/build/output.wasm")" = "workspace artifact" ]
  [ -x "$HOME/.cargo/bin/worker-build" ]
}

@test "pack produces a deterministic archive digest" {
  mkdir -p "$GITHUB_WORKSPACE/build" "$HOME/.cargo/bin"
  printf 'workspace artifact\n' > "$GITHUB_WORKSPACE/build/output.wasm"
  printf '#!/bin/sh\n' > "$HOME/.cargo/bin/worker-build"
  chmod +x "$HOME/.cargo/bin/worker-build"
  first="$TEST_ROOT/first.tar.gz"
  second="$TEST_ROOT/second.tar.gz"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" pack \
    --archive "$first" --workspace "$GITHUB_WORKSPACE" --home "$HOME" \
    --path "$GITHUB_WORKSPACE/build" --path "$HOME/.cargo/bin/worker-build"
  [ "$status" -eq 0 ]

  run python3 "$ACTION_ROOT/cache-v2-archive.py" pack \
    --archive "$second" --workspace "$GITHUB_WORKSPACE" --home "$HOME" \
    --path "$GITHUB_WORKSPACE/build" --path "$HOME/.cargo/bin/worker-build"
  [ "$status" -eq 0 ]

  [ "$(sha256_file "$first")" = "$(sha256_file "$second")" ]
}

@test "restore rejects an existing symlinked parent even within an allowed root" {
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"
  mkdir -p "$HOME/redirected/bin"
  ln -s "$HOME/redirected" "$HOME/.cargo"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe existing destination"* ]]
  [ ! -e "$HOME/redirected/bin/worker-build" ]
}

@test "restore remains inside its opened root when a parent is swapped after validation" {
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"
  mkdir -p "$HOME/.cargo/bin" "$TEST_ROOT/outside/bin"

  run python3 - "$ACTION_ROOT/cache-v2-archive.py" "$archive" \
    "$GITHUB_WORKSPACE" "$HOME" "$TEST_ROOT/outside" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

script, archive, workspace, home, outside = sys.argv[1:]
spec = importlib.util.spec_from_file_location("cache_v2_archive", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

original_extractfile = module.tarfile.TarFile.extractfile
swapped = False

def swap_parent_after_validation(tar, member):
    global swapped
    if not swapped and member.isfile():
        Path(home, ".cargo").rename(Path(home, ".cargo-original"))
        os.symlink(outside, Path(home, ".cargo"))
        swapped = True
    return original_extractfile(tar, member)

module.tarfile.TarFile.extractfile = swap_parent_after_validation
module.restore(Path(archive), Path(workspace), Path(home))
PY

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/outside/bin/worker-build" ]
  [ "$(cat "$HOME/.cargo-original/bin/worker-build")" = "safe executable" ]
}

@test "restore rejects an existing non-regular destination without blocking" {
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"
  mkdir -p "$HOME/.cargo/bin"
  mkfifo "$HOME/.cargo/bin/worker-build"

  run python3 - "$ACTION_ROOT/cache-v2-archive.py" "$archive" \
    "$GITHUB_WORKSPACE" "$HOME" <<'PY'
import subprocess
import sys

script, archive, workspace, home = sys.argv[1:]
try:
    result = subprocess.run(
        [sys.executable, script, "restore", "--archive", archive,
         "--workspace", workspace, "--home", home],
        capture_output=True,
        text=True,
        timeout=2,
    )
except subprocess.TimeoutExpired:
    print("restore blocked on an existing FIFO", file=sys.stderr)
    raise SystemExit(124)
sys.stdout.write(result.stderr)
raise SystemExit(result.returncode)
PY

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe existing destination"* ]]
}

@test "restore rejects members that normalize to the same destination" {
  archive="$TEST_ROOT/duplicate.tar.gz"
  make_archive duplicate "$archive"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate archive destination"* ]]
}

@test "restore refuses a checksum mismatch before extraction" {
  [ -f "$ACTION_ROOT/cache-v2.sh" ]
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"
  cp "$archive" "$TEST_ROOT/download.tar.gz"
  export CURL_ARGS_LOG="$TEST_ROOT/curl-args"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CURL_ARGS_LOG"
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
printf 'HTTP/1.1 200 OK\r\nX-Cache-SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n' > "$headers"
printf '200'
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"
  export CACHE_TOKEN="read-token-placeholder"
  export ACTION_PATH="$ACTION_ROOT"

  run bash "$ACTION_ROOT/cache-v2.sh" restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.cargo/bin/worker-build" ]
  grep -Fxq -- '--max-filesize' "$CURL_ARGS_LOG"
  grep -Fxq '94371840' "$CURL_ARGS_LOG"
}

@test "v2 restore rejects prefix fallback without contacting the cache" {
  export CACHE_TOKEN="read-token-placeholder"
  export ACTION_PATH="$ACTION_ROOT"
  export RESTORE_KEYS="pistachiorama/tool/linux/x64/"
  export CURL_CALLED="$TEST_ROOT/curl-called"
  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
touch "$CURL_CALLED"
exit 1
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"

  run bash "$ACTION_ROOT/cache-v2.sh" restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support restore-keys"* ]]
  [ ! -e "$CURL_CALLED" ]
}

@test "save uploads the computed digest and treats HTTP 409 as a conflict" {
  [ -f "$ACTION_ROOT/cache-v2.sh" ]
  mkdir -p "$HOME/.cargo/bin"
  printf '#!/bin/sh\n' > "$HOME/.cargo/bin/worker-build"
  chmod +x "$HOME/.cargo/bin/worker-build"
  export CACHE_PATH="$HOME/.cargo/bin/worker-build"
  export ACTION_PATH="$ACTION_ROOT"
  export CURL_ARGS_LOG="$TEST_ROOT/curl-args"
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.actions.invalid?id=1'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN='request-token-placeholder'
  export CURL_COUNT="$TEST_ROOT/curl-count"
  printf '0\n' > "$CURL_COUNT"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
count=$(( $(cat "$CURL_COUNT") + 1 ))
printf '%s\n' "$count" > "$CURL_COUNT"
if [ "$count" -eq 1 ]; then
  output=''
  while [ "$#" -gt 0 ]; do
    case "$1" in -o) output="$2"; shift 2 ;; *) shift ;; esac
  done
  printf '{"value":"oidc-jwt-placeholder"}' > "$output"
  exit 0
fi
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
  [ "$(cat "$CURL_COUNT")" = '2' ]
}

@test "v2 save fails before packing when GitHub OIDC is unavailable" {
  export CACHE_PATH="$HOME/.cargo/bin/worker-build"
  export ACTION_PATH="$ACTION_ROOT"
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN

  run bash "$ACTION_ROOT/cache-v2.sh" save

  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub OIDC permission is required"* ]]
}

@test "composite exposes additive v2 inputs and dispatches to scripts" {
  action="$ACTION_ROOT/action.yml"

  grep -q '^  api-version:' "$action"
  grep -q '^  read-token:' "$action"
  ! grep -q '^  write-token:' "$action"
  grep -q 'cache-v2.sh.*restore' "$action"
  grep -q 'cache-v2.sh.*save' "$action"
  grep -q "inputs.api-version != 'v1'.*inputs.api-version != 'v2'" "$action"
  [ "$(grep -c 'CACHE_API_VERSION: v2' "$action")" -eq 2 ]
}
