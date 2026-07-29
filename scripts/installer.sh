#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"

log() {
  printf '[%s] %s\n' "$PROGRAM_NAME" "$*"
}

die() {
  printf '[%s] Errore: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

as_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "sono necessari i privilegi di amministratore, ma sudo non è installato."
  fi
}

install_github_cli() {
  if command -v brew >/dev/null 2>&1; then
    log "Installazione di GitHub CLI tramite Homebrew..."
    brew install gh
  elif command -v apt-get >/dev/null 2>&1; then
    log "Installazione di GitHub CLI tramite APT..."
    as_root apt-get update
    as_root apt-get install -y gh
  elif command -v dnf >/dev/null 2>&1; then
    log "Installazione di GitHub CLI tramite DNF..."
    as_root dnf install -y gh
  elif command -v yum >/dev/null 2>&1; then
    log "Installazione di GitHub CLI tramite YUM..."
    as_root yum install -y gh
  elif command -v pacman >/dev/null 2>&1; then
    log "Installazione di GitHub CLI tramite Pacman..."
    as_root pacman -S --needed --noconfirm github-cli
  elif command -v zypper >/dev/null 2>&1; then
    log "Installazione di GitHub CLI tramite Zypper..."
    as_root zypper --non-interactive install gh
  else
    die "package manager non supportato. Installa GitHub CLI da https://cli.github.com/."
  fi
}

main() {
  if command -v gh >/dev/null 2>&1; then
    log "GitHub CLI è già installato: $(gh --version | head -n 1)"
    return
  fi

  log "GitHub CLI non è installato."
  install_github_cli

  command -v gh >/dev/null 2>&1 ||
    die "l'installazione è terminata, ma il comando 'gh' non è disponibile nel PATH."

  log "GitHub CLI installato correttamente: $(gh --version | head -n 1)"
  log "Per autenticarti, esegui: gh auth login"
}

main "$@"
