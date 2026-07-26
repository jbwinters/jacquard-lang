#!/usr/bin/env bash

set -u

opam_bin=${OPAM_BIN:-opam}
attempt_limit=${OPAM_INSTALL_ATTEMPTS:-3}
retry_delay=${OPAM_INSTALL_RETRY_DELAY_SECONDS:-15}

case "$attempt_limit" in
  ''|*[!0-9]*)
    echo "OPAM_INSTALL_ATTEMPTS must be a positive integer" >&2
    exit 64
    ;;
esac
if [ "$attempt_limit" -lt 1 ]; then
  echo "OPAM_INSTALL_ATTEMPTS must be a positive integer" >&2
  exit 64
fi

case "$retry_delay" in
  ''|*[!0-9]*)
    echo "OPAM_INSTALL_RETRY_DELAY_SECONDS must be a non-negative integer" >&2
    exit 64
    ;;
esac

attempt=1
while :; do
  "$opam_bin" install "$@"
  status=$?
  if [ "$status" -eq 0 ]; then
    exit 0
  fi
  if [ "$status" -ne 40 ]; then
    echo "opam dependency installation failed with non-sync status $status; not retrying" >&2
    exit "$status"
  fi
  if [ "$attempt" -ge "$attempt_limit" ]; then
    echo "opam dependency download failed after $attempt attempt(s)" >&2
    exit "$status"
  fi

  echo "opam dependency download failed on attempt $attempt/$attempt_limit; retrying in ${retry_delay}s" >&2
  sleep "$retry_delay"
  attempt=$((attempt + 1))
done
