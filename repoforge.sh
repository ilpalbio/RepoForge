#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPTS_DIR="$PROJECT_DIR/scripts"
readonly GITHUB_SCRIPTS_DIR="$SCRIPTS_DIR/github"

source "$SCRIPTS_DIR/log/log.sh"

export REPOFORGE_LOG_PROGRAM_NAME="$PROGRAM_NAME"

CONFIG_FILE=""

cleanup() {
  if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    rm -f -- "$CONFIG_FILE"
  fi
}

trap cleanup EXIT HUP INT TERM

usage() {
  local manifest_arg="[MANIFEST]"
  local manifest_help="Se MANIFEST non è specificato, viene utilizzato ./repoforge.yaml."

  if [[ "${REPOFORGE_REQUIRE_MANIFEST:-0}" == "1" ]]; then
    manifest_arg="MANIFEST"
    manifest_help="In Docker, monta la directory della configurazione e passa il percorso di MANIFEST nel container."
  fi

  cat <<EOF
Uso:
  $PROGRAM_NAME install
  $PROGRAM_NAME validate $manifest_arg
  $PROGRAM_NAME --dry-run $manifest_arg [--repo OWNER/REPOSITORY]
  $PROGRAM_NAME apply $manifest_arg [--repo OWNER/REPOSITORY]

Comandi:
  install    Installa e verifica le dipendenze locali.
  validate   Carica e valida la configurazione senza contattare GitHub.
  --dry-run  Mostra il riepilogo delle risorse che verrebbero applicate.
  apply      Sincronizza la configurazione con il repository GitHub.

Opzioni:
  --repo OWNER/REPOSITORY  Sovrascrive il repository definito nel manifest.
  -h, --help               Mostra questo messaggio.

$manifest_help
EOF
}

require_executable() {
  [[ -x "$1" ]] ||
    die "script non trovato o non eseguibile: $1"
}

load_and_validate() {
  local manifest="$1"

  require_executable "$SCRIPTS_DIR/loader.sh"
  require_executable "$SCRIPTS_DIR/validator.sh"

  CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/repoforge-config.XXXXXXXX")"

  log "Caricamento configurazione: $manifest"
  "$SCRIPTS_DIR/loader.sh" "$manifest" >"$CONFIG_FILE" ||
    die "caricamento della configurazione non riuscito."

  log "Validazione configurazione..."
  "$SCRIPTS_DIR/validator.sh" "$CONFIG_FILE" ||
    die "validazione della configurazione non riuscita."
}

resolve_repository() {
  local override="$1"
  local owner name repository

  if [[ -n "$override" ]]; then
    repository="$override"
  else
    owner="$(jq -r '.repository.owner // empty' "$CONFIG_FILE")"
    name="$(jq -r '.repository.name // empty' "$CONFIG_FILE")"
    [[ -n "$owner" && -n "$name" ]] ||
      die "il manifest non definisce repository.owner e repository.name."
    repository="$owner/$name"
  fi

  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "repository non valido: usa il formato OWNER/REPOSITORY."
  printf '%s\n' "$repository"
}

show_dry_run() {
  local repository="$1"

  printf '\nDry run RepoForge\n'
  printf '=================\n'
  printf '  %-24s %s\n' "Repository" "$repository"
  printf '  %-24s %s\n' "Label" "$(jq '.labels | length' "$CONFIG_FILE")"
  printf '  %-24s %s\n' "Milestone" "$(jq '.milestones | length' "$CONFIG_FILE")"
  printf '  %-24s %s\n' "Issue" "$(jq '.issues | length' "$CONFIG_FILE")"
  printf '  %-24s %s\n' "Issue aperte" \
    "$(jq '[.issues[] | select((.state // "open") == "open")] | length' "$CONFIG_FILE")"
  printf '  %-24s %s\n' "Issue chiuse" \
    "$(jq '[.issues[] | select(.state == "closed")] | length' "$CONFIG_FILE")"
  printf '  %-24s %s\n' "Assegnazioni" \
    "$(jq '[.issues[].assignees[]?] | length' "$CONFIG_FILE")"
  printf '  %-24s %s\n' "Dipendenze" \
    "$(jq '[.issues[].dependencies[]?] | length' "$CONFIG_FILE")"
  printf '\n'
  log "Dry run completato: nessuna modifica effettuata."
}

apply_configuration() {
  local repository="$1"
  local script
  local -a required_scripts=(
    "$GITHUB_SCRIPTS_DIR/auth.sh"
    "$GITHUB_SCRIPTS_DIR/labels.sh"
    "$GITHUB_SCRIPTS_DIR/milestones.sh"
    "$GITHUB_SCRIPTS_DIR/issues.sh"
    "$GITHUB_SCRIPTS_DIR/issues-metadata.sh"
    "$GITHUB_SCRIPTS_DIR/summary.sh"
  )

  for script in "${required_scripts[@]}"; do
    require_executable "$script"
  done

  log "Verifica accesso amministrativo a $repository..."
  "$GITHUB_SCRIPTS_DIR/auth.sh" "$repository" admin

  log "Sincronizzazione label..."
  "$GITHUB_SCRIPTS_DIR/labels.sh" "$repository" "$CONFIG_FILE"

  log "Sincronizzazione milestone..."
  "$GITHUB_SCRIPTS_DIR/milestones.sh" "$repository" "$CONFIG_FILE"

  log "Sincronizzazione issue..."
  "$GITHUB_SCRIPTS_DIR/issues.sh" "$repository" "$CONFIG_FILE"

  log "Applicazione stato, assegnatari e dipendenze..."
  "$GITHUB_SCRIPTS_DIR/issues-metadata.sh" "$repository" "$CONFIG_FILE"

  log "Generazione riepilogo finale..."
  "$GITHUB_SCRIPTS_DIR/summary.sh" "$repository" "$CONFIG_FILE"
}

main() {
  local mode=""
  local manifest=""
  local repository_override=""

  while (($# > 0)); do
    case "$1" in
      install)
        [[ -z "$mode" ]] || die "è possibile specificare un solo comando."
        mode="install"
        ;;
      validate)
        [[ -z "$mode" ]] || die "è possibile specificare un solo comando."
        mode="validate"
        ;;
      apply)
        [[ -z "$mode" ]] || die "è possibile specificare un solo comando."
        mode="apply"
        ;;
      --dry-run)
        [[ -z "$mode" ]] || die "è possibile specificare un solo comando."
        mode="dry-run"
        ;;
      --repo)
        shift
        (($# > 0)) || die "l'opzione --repo richiede OWNER/REPOSITORY."
        repository_override="$1"
        ;;
      -h | --help)
        usage
        return
        ;;
      -*)
        die "opzione non riconosciuta: $1"
        ;;
      *)
        [[ -z "$manifest" ]] ||
          die "è possibile specificare un solo manifest."
        manifest="$1"
        ;;
    esac
    shift
  done

  mode="${mode:-dry-run}"

  if [[ "$mode" == "install" ]]; then
    [[ -z "$repository_override" ]] ||
      die "l'opzione --repo non è valida con il comando install."
    [[ -z "$manifest" || "$manifest" == "repoforge.yaml" ]] ||
      die "il comando install non accetta un manifest."
    require_executable "$SCRIPTS_DIR/installer.sh"
    "$SCRIPTS_DIR/installer.sh"
    return
  fi

  if [[ -z "$manifest" && "${REPOFORGE_REQUIRE_MANIFEST:-0}" == "1" ]]; then
    die "manifest obbligatorio: monta la directory della configurazione e passa il percorso del manifest nel container."
  fi

  load_and_validate "${manifest:-repoforge.yaml}"

  if [[ "$mode" == "validate" ]]; then
    log "Configurazione valida."
    return
  fi

  local repository
  repository="$(resolve_repository "$repository_override")"

  case "$mode" in
    dry-run) show_dry_run "$repository" ;;
    apply) apply_configuration "$repository" ;;
  esac
}

main "$@"
