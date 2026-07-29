#!/usr/bin/env bash

# Funzioni di logging condivise dagli script RepoForge.

log() {
  printf '[%s] %s\n' \
    "${REPOFORGE_LOG_PROGRAM_NAME:-${PROGRAM_NAME:-${0##*/}}}" "$*"
}

log_error() {
  printf '[%s] Errore: %s\n' \
    "${REPOFORGE_LOG_PROGRAM_NAME:-${PROGRAM_NAME:-${0##*/}}}" "$*" >&2
}

die() {
  log_error "$@"
  exit 1
}
