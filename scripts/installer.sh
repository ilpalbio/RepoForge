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

install_curl() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi

  log "Installazione di curl, necessario per scaricare yq..."
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update
    as_root apt-get install -y ca-certificates curl
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y ca-certificates curl
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y ca-certificates curl
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --needed --noconfirm ca-certificates curl
  elif command -v zypper >/dev/null 2>&1; then
    as_root zypper --non-interactive install ca-certificates curl
  else
    die "impossibile installare curl: package manager non supportato."
  fi
}

install_yq() {
  local architecture download_url temporary_file

  if command -v brew >/dev/null 2>&1; then
    log "Installazione di yq tramite Homebrew..."
    brew install yq
    return
  fi

  install_curl

  case "$(uname -m)" in
    x86_64 | amd64) architecture="amd64" ;;
    aarch64 | arm64) architecture="arm64" ;;
    armv7l | armv7) architecture="arm" ;;
    *) die "architettura non supportata per yq: $(uname -m)." ;;
  esac

  download_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${architecture}"
  temporary_file="$(mktemp "${TMPDIR:-/tmp}/yq.XXXXXXXX")"

  log "Download del binario ufficiale di yq v4..."
  if ! curl --fail --location --silent --show-error \
    "$download_url" --output "$temporary_file"; then
    rm -f -- "$temporary_file"
    die "download di yq non riuscito."
  fi

  as_root install -m 0755 "$temporary_file" /usr/local/bin/yq
  rm -f -- "$temporary_file"
}

install_jq() {
  if command -v brew >/dev/null 2>&1; then
    log "Installazione di jq tramite Homebrew..."
    brew install jq
  elif command -v apt-get >/dev/null 2>&1; then
    log "Installazione di jq tramite APT..."
    as_root apt-get update
    as_root apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then
    log "Installazione di jq tramite DNF..."
    as_root dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then
    log "Installazione di jq tramite YUM..."
    as_root yum install -y jq
  elif command -v pacman >/dev/null 2>&1; then
    log "Installazione di jq tramite Pacman..."
    as_root pacman -S --needed --noconfirm jq
  elif command -v zypper >/dev/null 2>&1; then
    log "Installazione di jq tramite Zypper..."
    as_root zypper --non-interactive install jq
  else
    die "package manager non supportato. Installa jq da https://jqlang.org/."
  fi
}

main() {
  if command -v gh >/dev/null 2>&1; then
    log "GitHub CLI è già installato: $(gh --version | head -n 1)"
  else
    log "GitHub CLI non è installato."
    install_github_cli
    command -v gh >/dev/null 2>&1 ||
      die "l'installazione è terminata, ma il comando 'gh' non è disponibile nel PATH."
    log "GitHub CLI installato correttamente: $(gh --version | head -n 1)"
  fi

  if command -v yq >/dev/null 2>&1 &&
    yq --version 2>&1 | grep -Eq 'version v?4\.'; then
    log "yq v4 è già installato: $(yq --version)"
  else
    log "yq v4 non è installato."
    install_yq
    command -v yq >/dev/null 2>&1 ||
      die "l'installazione è terminata, ma il comando 'yq' non è disponibile nel PATH."
    yq --version 2>&1 | grep -Eq 'version v?4\.' ||
      die "la versione installata di yq non è compatibile: è richiesta la v4."
    log "yq installato correttamente: $(yq --version)"
  fi

  if command -v jq >/dev/null 2>&1; then
    log "jq è già installato: $(jq --version)"
  else
    log "jq non è installato."
    install_jq
    command -v jq >/dev/null 2>&1 ||
      die "l'installazione è terminata, ma il comando 'jq' non è disponibile nel PATH."
    log "jq installato correttamente: $(jq --version)"
  fi

  log "Installazione delle dipendenze completata."
  log "Per autenticare GitHub CLI, esegui: gh auth login"
}

main "$@"
