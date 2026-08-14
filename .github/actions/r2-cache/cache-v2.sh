#!/usr/bin/env bash
set -euo pipefail

: "${ACTION_PATH:?ACTION_PATH is required}"
: "${CACHE_API:?CACHE_API is required}"
: "${CACHE_KEY:?CACHE_KEY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# shellcheck source=/dev/null
source "${ACTION_PATH}/curl-retry.sh"

MAX_COMPRESSED_BYTES=94371840
OIDC_AUDIENCE=ci-cache.pistachiorama.ai
TEMP_FILES=()

cleanup_temp_files() {
  local path
  for path in "${TEMP_FILES[@]}"; do
    rm -f "$path"
  done
}
trap cleanup_temp_files EXIT

write_bearer_config() {
  local token="$1"
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* \
    && "$token" != *'"'* && "$token" != *\\* ]] \
    || { echo "r2-cache-v2: unsafe bearer framing" >&2; return 1; }
  printf 'header = "Authorization: Bearer %s"\n' "$token"
}

write_bearer_config_file() {
  local token="$1" destination="$2"
  umask 077
  write_bearer_config "$token" > "$destination"
}

encoded_cache_key() {
  python3 - "$CACHE_KEY" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe="/-._~"), end="")
PY
}

github_oidc_token() {
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?GitHub OIDC permission is required for v2 save}"
  : "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?GitHub OIDC permission is required for v2 save}"
  local response request_config token
  response="$(mktemp)"
  request_config="$(mktemp)"
  TEMP_FILES+=("$response" "$request_config")
  write_bearer_config_file "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$request_config"
  if ! curl_with_retry -q -sS --config "$request_config" -o "$response" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${OIDC_AUDIENCE}"; then
    rm -f "$response" "$request_config"
    return 1
  fi
  token="$(python3 - "$response" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source).get("value")
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value, end="")
PY
)" || {
    rm -f "$response" "$request_config"
    echo "r2-cache-v2: GitHub OIDC response was invalid" >&2
    return 1
  }
  rm -f "$response" "$request_config"
  write_bearer_config "$token" >/dev/null
  printf '%s' "$token"
}

_millis() {
  command -v get_millis >/dev/null 2>&1 && get_millis \
    || python3 -c 'import time; print(int(time.time() * 1000))' \
    || echo 0
}

_emit() {
  command -v emit_r2_cache_event >/dev/null 2>&1 && emit_r2_cache_event "$@" || true
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

archive_bytes() {
  wc -c < "$1" | tr -d ' '
}

load_metrics() {
  [[ -z "${AXIOM_TOKEN:-}" || -z "${METRICS_SCRIPT:-}" ]] && return 0
  [[ "$METRICS_SCRIPT" != *".."* ]] || { echo "r2-cache-v2: invalid metrics-script" >&2; return 1; }
  local metrics_path="$GITHUB_WORKSPACE/$METRICS_SCRIPT"
  [[ -f "$metrics_path" ]] || { echo "::warning::metrics script not found; telemetry skipped"; return 0; }
  # shellcheck source=/dev/null
  source "$metrics_path"
}

restore_cache() {
  local archive headers http_code expected actual size start cache_key_url
  : "${CACHE_TOKEN:?CACHE_TOKEN is required for v2 restore}"
  [[ ! "${RESTORE_KEYS:-}" =~ [^[:space:]] ]] \
    || { echo "r2-cache-v2: exact cache does not support restore-keys" >&2; return 1; }
  archive="$(mktemp)"
  headers="$(mktemp)"
  TEMP_FILES+=("$archive" "$headers")
  start="$(_millis)"
  cache_key_url="$(encoded_cache_key)"
  http_code="$(curl_with_retry -q -sS --max-filesize "$MAX_COMPRESSED_BYTES" \
    -D "$headers" -o "$archive" -w '%{http_code}' \
    -H "Authorization: Bearer $CACHE_TOKEN" "$CACHE_API/v2/cache/$cache_key_url")" || http_code=000
  case "$http_code" in
    404)
      echo "cache-hit=false" >> "$GITHUB_OUTPUT"
      _emit r2_cache_miss "$CACHE_KEY" 404 "$(( $(_millis) - start ))"
      return 0
      ;;
    200) ;;
    *)
      _emit r2_cache_error "$CACHE_KEY" "$http_code" "$(( $(_millis) - start ))"
      echo "r2-cache-v2: restore failed (HTTP $http_code)" >&2
      return 1
      ;;
  esac
  expected="$(tr -d '\r' < "$headers" | awk 'tolower($1) == "x-cache-sha256:" {print $2; exit}')"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    _emit r2_cache_error "$CACHE_KEY" 200 "$(( $(_millis) - start ))"
    echo "r2-cache-v2: missing or invalid checksum metadata" >&2
    return 1
  }
  actual="$(sha256_file "$archive")"
  [[ "$actual" == "$expected" ]] || {
    _emit r2_cache_error "$CACHE_KEY" 200 "$(( $(_millis) - start ))"
    echo "r2-cache-v2: checksum mismatch" >&2
    return 1
  }
  size="$(archive_bytes "$archive")"
  if ! python3 "$ACTION_PATH/cache-v2-archive.py" restore \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME"; then
    _emit r2_cache_error "$CACHE_KEY" 200 "$(( $(_millis) - start ))"
    return 1
  fi
  echo "cache-hit=true" >> "$GITHUB_OUTPUT"
  echo "matched-key=$CACHE_KEY" >> "$GITHUB_OUTPUT"
  _emit r2_cache_restore "$CACHE_KEY" 200 "$(( $(_millis) - start ))" "$CACHE_KEY" "$size"
}

save_cache() {
  local archive http_code digest size start raw_path oidc_token upload_config cache_key_url
  local -a pack_paths=()
  archive="$(mktemp)"
  TEMP_FILES+=("$archive")
  while IFS= read -r raw_path; do
    [[ -n "$raw_path" ]] && pack_paths+=(--path "$raw_path")
  done <<< "${CACHE_PATH:-}"
  [[ ${#pack_paths[@]} -gt 0 ]] || { echo "r2-cache-v2: CACHE_PATH is required" >&2; return 1; }
  oidc_token="$(github_oidc_token)"
  python3 "$ACTION_PATH/cache-v2-archive.py" pack \
    --archive "$archive" --workspace "$GITHUB_WORKSPACE" --home "$HOME" "${pack_paths[@]}"
  digest="$(sha256_file "$archive")"
  size="$(archive_bytes "$archive")"
  if (( size > MAX_COMPRESSED_BYTES )); then
    echo "r2-cache-v2: compressed cache exceeds the allowed size" >&2
    return 1
  fi
  upload_config="$(mktemp)"
  TEMP_FILES+=("$upload_config")
  write_bearer_config_file "$oidc_token" "$upload_config"
  unset oidc_token
  cache_key_url="$(encoded_cache_key)"
  start="$(_millis)"
  http_code="$(curl_with_retry -q -sS -X PUT -o /dev/null -w '%{http_code}' \
    --config "$upload_config" \
    -H 'Content-Type: application/gzip' \
    -H "X-Cache-SHA256: $digest" \
    -H 'If-None-Match: *' \
    --data-binary "@$archive" "$CACHE_API/v2/cache/$cache_key_url")" || http_code=000
  rm -f "$upload_config"
  case "$http_code" in
    200|201)
      _emit r2_cache_save "$CACHE_KEY" "$http_code" "$(( $(_millis) - start ))" "" "$size"
      ;;
    409)
      _emit r2_cache_error "$CACHE_KEY" 409 "$(( $(_millis) - start ))"
      echo "r2-cache-v2: immutable key conflict" >&2
      return 1
      ;;
    *)
      _emit r2_cache_error "$CACHE_KEY" "$http_code" "$(( $(_millis) - start ))"
      echo "r2-cache-v2: save failed (HTTP $http_code)" >&2
      return 1
      ;;
  esac
}

load_metrics
case "${1:-}" in
  restore) restore_cache ;;
  save) save_cache ;;
  *) echo "usage: cache-v2.sh restore|save" >&2; exit 2 ;;
esac
