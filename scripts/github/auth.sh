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

usage() {
  cat <<EOF
Uso: $PROGRAM_NAME OWNER/REPOSITORY [PERMESSO]

Controlla l'autenticazione GitHub CLI e il permesso dell'utente sul repository.

Permessi supportati, dal più basso al più alto:
  read, triage, write, maintain, admin

Se PERMESSO non è specificato, viene richiesto il livello "admin".
EOF
}

permission_rank() {
  case "${1,,}" in
    read) printf '1\n' ;;
    triage) printf '2\n' ;;
    write) printf '3\n' ;;
    maintain) printf '4\n' ;;
    admin) printf '5\n' ;;
    *) return 1 ;;
  esac
}

check_github_access() {
  local repository="$1"
  local required_permission="${2:-admin}"
  local username actual_permission required_rank actual_rank
  local api_error_file

  command -v gh >/dev/null 2>&1 ||
    die "GitHub CLI non è installato. Esegui scripts/installer.sh."

  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "repository non valido: usa il formato OWNER/REPOSITORY."

  required_rank="$(permission_rank "$required_permission")" ||
    die "permesso richiesto non valido: '$required_permission'."

  if ! gh api user >/dev/null 2>&1; then
    # Se l'utente non è autenticato, avvia il flusso interattivo di GitHub CLI.
    if [[ -t 0 && -t 1 ]]; then
      log "GitHub CLI non è autenticato. Avvio dell'autenticazione..."
      gh auth login ||
        die "autenticazione GitHub non riuscita."
    else
      die "GitHub CLI non è autenticato e il terminale non è interattivo. Esegui: gh auth login"
    fi

    gh api user >/dev/null 2>&1 ||
      die "GitHub CLI non risulta autenticato dopo il login."
  fi

  username="$(gh api user --jq '.login')" ||
    die "impossibile determinare l'utente GitHub autenticato."

  api_error_file="$(mktemp "${TMPDIR:-/tmp}/repoforge-gh-auth.XXXXXXXX")"
  if ! actual_permission="$(
    gh repo view "$repository" \
      --json viewerPermission \
      --jq '.viewerPermission' 2>"$api_error_file"
  )"; then
    printf '[%s] Dettaglio GitHub: %s\n' \
      "$PROGRAM_NAME" "$(tr '\n' ' ' <"$api_error_file")" >&2
    rm -f -- "$api_error_file"
    die "il repository '$repository' non esiste o non è accessibile."
  fi
  rm -f -- "$api_error_file"

  actual_permission="${actual_permission,,}"
  actual_rank="$(permission_rank "$actual_permission")" ||
    die "GitHub ha restituito un permesso non riconosciuto: '$actual_permission'."

  if ((actual_rank < required_rank)); then
    die "l'utente '$username' ha permesso '$actual_permission' su '$repository', ma è richiesto '$required_permission'."
  fi

  log "Utente autenticato: $username"
  log "Repository accessibile: $repository"
  log "Permesso verificato: $actual_permission (richiesto: ${required_permission,,})"
}

main() {
  if (($# < 1 || $# > 2)); then
    usage >&2
    return 2
  fi

  case "$1" in
    -h | --help)
      usage
      return
      ;;
  esac

  check_github_access "$1" "${2:-admin}"
}

main "$@"
