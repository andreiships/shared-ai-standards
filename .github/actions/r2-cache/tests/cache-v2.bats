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

@test "pack deduplicates recursive glob descendants" {
  mkdir -p "$GITHUB_WORKSPACE/build/nested"
  printf 'artifact\n' > "$GITHUB_WORKSPACE/build/nested/output.wasm"

  run python3 "$ACTION_ROOT/cache-v2-archive.py" pack \
    --archive "$TEST_ROOT/glob.tar.gz" --workspace "$GITHUB_WORKSPACE" --home "$HOME" \
    --path "$GITHUB_WORKSPACE/build/**"

  [ "$status" -eq 0 ]
  run tar tzf "$TEST_ROOT/glob.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'workspace/build/nested/output.wasm')" -eq 1 ]
}

@test "pack enforces the restore member and size contract" {
  mkdir -p "$GITHUB_WORKSPACE/build"
  printf 'one\n' > "$GITHUB_WORKSPACE/build/one"
  printf 'two\n' > "$GITHUB_WORKSPACE/build/two"

  run python3 - "$ACTION_ROOT/cache-v2-archive.py" "$TEST_ROOT/limit.tar.gz" \
    "$GITHUB_WORKSPACE" "$HOME" <<'PY'
import importlib.util
from pathlib import Path
import sys

script, archive, workspace, home = sys.argv[1:]
spec = importlib.util.spec_from_file_location("cache_v2_archive", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.MAX_MEMBERS = 2
module.pack(Path(archive), Path(workspace), Path(home), [str(Path(workspace, "build"))])
PY

  [ "$status" -ne 0 ]
  [[ "$output" == *"too many members"* ]]

  run python3 - "$ACTION_ROOT/cache-v2-archive.py" "$TEST_ROOT/size.tar.gz" \
    "$GITHUB_WORKSPACE" "$HOME" <<'PY'
import importlib.util
from pathlib import Path
import sys

script, archive, workspace, home = sys.argv[1:]
spec = importlib.util.spec_from_file_location("cache_v2_archive", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.MAX_UNCOMPRESSED_BYTES = 1
module.pack(Path(archive), Path(workspace), Path(home), [str(Path(workspace, "build/one"))])
PY

  [ "$status" -ne 0 ]
  [[ "$output" == *"exceeds the allowed size"* ]]
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
  export AXIOM_TOKEN="axiom-placeholder"
  export METRICS_SCRIPT="r2-cache-metrics-test.sh"
  export METRICS_LOG="$TEST_ROOT/metrics-log"
  cat > "$GITHUB_WORKSPACE/$METRICS_SCRIPT" <<'SH'
emit_r2_cache_event() { printf '%s\n' "$1" >> "$METRICS_LOG"; }
get_millis() { printf '1000\n'; }
SH

  run bash "$ACTION_ROOT/cache-v2.sh" restore

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.cargo/bin/worker-build" ]
  grep -Fxq -- '--max-filesize' "$CURL_ARGS_LOG"
  grep -Fxq '94371840' "$CURL_ARGS_LOG"
  grep -Fxq 'r2_cache_error' "$METRICS_LOG"
}

@test "successful v2 restore emits the verified compressed archive size" {
  archive="$TEST_ROOT/valid.tar.gz"
  make_archive valid "$archive"
  export DOWNLOAD_ARCHIVE="$archive"
  export EXPECTED_DIGEST
  EXPECTED_DIGEST="$(sha256_file "$archive")"
  export ACTION_PATH="$ACTION_ROOT"
  export CACHE_TOKEN="read-token-placeholder"
  export AXIOM_TOKEN="axiom-placeholder"
  export METRICS_SCRIPT="r2-cache-metrics-test.sh"
  export METRICS_LOG="$TEST_ROOT/metrics-log"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=''
headers=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$DOWNLOAD_ARCHIVE" "$output"
printf 'HTTP/1.1 200 OK\r\nX-Cache-SHA256: %s\r\n\r\n' "$EXPECTED_DIGEST" > "$headers"
printf '200'
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"
  cat > "$GITHUB_WORKSPACE/$METRICS_SCRIPT" <<'SH'
emit_r2_cache_event() { printf '%s\n' "$*" > "$METRICS_LOG"; }
get_millis() { printf '1000\n'; }
SH

  run bash "$ACTION_ROOT/cache-v2.sh" restore

  [ "$status" -eq 0 ]
  [ "$(awk '{print $1}' "$METRICS_LOG")" = "r2_cache_restore" ]
  [ "$(awk '{print $6}' "$METRICS_LOG")" = "$(wc -c < "$archive" | tr -d ' ')" ]
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

@test "successful v2 save emits the uploaded compressed archive size" {
  mkdir -p "$HOME/.cargo/bin"
  printf '#!/bin/sh\n' > "$HOME/.cargo/bin/worker-build"
  chmod +x "$HOME/.cargo/bin/worker-build"
  export CACHE_PATH="$HOME/.cargo/bin/worker-build"
  export ACTION_PATH="$ACTION_ROOT"
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.actions.invalid?id=1'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN='request-token-placeholder'
  export AXIOM_TOKEN="axiom-placeholder"
  export METRICS_SCRIPT="r2-cache-metrics-test.sh"
  export METRICS_LOG="$TEST_ROOT/metrics-log"
  export UPLOAD_SIZE_LOG="$TEST_ROOT/upload-size"
  export CURL_COUNT="$TEST_ROOT/curl-count"
  printf '0\n' > "$CURL_COUNT"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-binary) wc -c < "${2#@}" | tr -d ' ' > "$UPLOAD_SIZE_LOG"; shift 2 ;;
    *) shift ;;
  esac
done
printf '201'
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"
  cat > "$GITHUB_WORKSPACE/$METRICS_SCRIPT" <<'SH'
emit_r2_cache_event() { printf '%s\n' "$*" > "$METRICS_LOG"; }
get_millis() { printf '1000\n'; }
SH

  run bash "$ACTION_ROOT/cache-v2.sh" save

  [ "$status" -eq 0 ]
  [ "$(awk '{print $1}' "$METRICS_LOG")" = "r2_cache_save" ]
  [ "$(awk '{print $6}' "$METRICS_LOG")" = "$(cat "$UPLOAD_SIZE_LOG")" ]
  [ "$(cat "$UPLOAD_SIZE_LOG")" -gt 0 ]
}

@test "v2 save fails before packing when GitHub OIDC is unavailable" {
  export CACHE_PATH="$HOME/.cargo/bin/worker-build"
  export ACTION_PATH="$ACTION_ROOT"
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN

  run bash "$ACTION_ROOT/cache-v2.sh" save

  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub OIDC permission is required"* ]]
}

@test "v2 OIDC and upload retries reuse private configs and disable curlrc" {
  mkdir -p "$HOME/.cargo/bin" "$TEST_ROOT/tmp"
  printf '#!/bin/sh\n' > "$HOME/.cargo/bin/worker-build"
  export CACHE_PATH="$HOME/.cargo/bin/worker-build"
  export CACHE_KEY='namespace/key?#percent%'
  export ACTION_PATH="$ACTION_ROOT"
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.actions.invalid?id=1'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN='request-token-placeholder'
  export CURL_COUNT="$TEST_ROOT/curl-count"
  export CURL_LOG="$TEST_ROOT/curl-log"
  export TMPDIR="$TEST_ROOT/tmp"
  export CURL_RETRY_BASE_DELAY=0
  printf '0\n' > "$CURL_COUNT"

  cat > "$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=$(( $(cat "$CURL_COUNT") + 1 ))
printf '%s\n' "$count" > "$CURL_COUNT"
config=''
output=''
url=''
disabled=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q|--disable) disabled=true; shift ;;
    --config) config="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$disabled" = true ]
[ -s "$config" ]
[ "$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")" = '600' ]
printf '%s %s\n' "$count" "$url" >> "$CURL_LOG"
if [ "$count" = 1 ] || [ "$count" = 3 ]; then
  exit 7
fi
if [ "$count" = 2 ]; then
  printf '{"value":"oidc-jwt-placeholder"}' > "$output"
  exit 0
fi
printf '201'
SH
  chmod +x "$TEST_ROOT/bin/curl"
  export PATH="$TEST_ROOT/bin:$PATH"

  run bash "$ACTION_ROOT/cache-v2.sh" save

  [ "$status" -eq 0 ]
  [ "$(cat "$CURL_COUNT")" = '4' ]
  grep -Fq 'namespace/key%3F%23percent%25' "$CURL_LOG"
  [ -z "$(find "$TEST_ROOT/tmp" -type f -print -quit)" ]
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
  grep -q 'id-token: write' "$action"
}
