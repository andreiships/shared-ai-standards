#!/usr/bin/env bash
# curl_with_retry — retry wrapper for curl with exponential backoff.
#
# Retries on transient network errors (exit codes 7, 28, 56).
# Non-retryable errors pass through immediately.
#
# Configuration (environment variables):
#   CURL_RETRY_MAX         — max attempts (default: 3)
#   CURL_RETRY_BASE_DELAY  — base delay in seconds for backoff (default: 1)
#
# Usage:
#   source scripts/lib/curl-retry.sh
#   curl_with_retry [curl args...]
#
# Returns: curl exit code (0 on success, last error code on exhaustion)
# Stdout:  curl stdout from the last attempted curl invocation
# Stderr:  ::warning:: annotations on each retry + exhaustion

CURL_RETRY_MAX="${CURL_RETRY_MAX:-3}"
CURL_RETRY_BASE_DELAY="${CURL_RETRY_BASE_DELAY:-1}"

curl_with_retry() {
  local attempt=1
  local exit_code=0
  local stdout_file
  stdout_file=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$stdout_file'" RETURN

  while (( attempt <= CURL_RETRY_MAX )); do
    exit_code=0
    # Redirect stdout to temp file; only the last attempt's output is forwarded.
    # Each attempt overwrites (>) so retried body data doesn't corrupt callers.
    curl "$@" > "$stdout_file" || exit_code=$?

    if (( exit_code == 0 )); then
      cat "$stdout_file"
      return 0
    fi

    # Only retry on transient network errors
    case "$exit_code" in
      7|28|56) ;;  # CURLE_COULDNT_CONNECT, CURLE_OPERATION_TIMEDOUT, CURLE_RECV_ERROR
      *)
        cat "$stdout_file"
        return "$exit_code"
        ;;
    esac

    if (( attempt < CURL_RETRY_MAX )); then
      local delay=$(( CURL_RETRY_BASE_DELAY * (1 << (attempt - 1)) ))
      echo "::warning::curl failed (exit $exit_code), retry ${attempt}/$CURL_RETRY_MAX in ${delay}s" >&2
      sleep "$delay"
    fi

    (( attempt++ ))
  done

  cat "$stdout_file"
  echo "::warning::curl failed after $CURL_RETRY_MAX attempts (last exit code: $exit_code)" >&2
  return "$exit_code"
}
