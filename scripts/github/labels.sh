#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source "$SCRIPT_DIR/../log/log.sh"

usage() {
  cat <<EOF
Uso: $PROGRAM_NAME OWNER/REPOSITORY FILE_JSON

Sincronizza le label definite in FILE_JSON con il repository GitHub.
Le label non presenti nella configurazione non vengono eliminate.
EOF
}

validate_inputs() {
  local repository="$1"
  local json_file="$2"
  local label id name color normalized_name
  local -A configured_names=()

  command -v gh >/dev/null 2>&1 ||
    die "GitHub CLI non è installato. Esegui scripts/installer.sh."
  command -v jq >/dev/null 2>&1 ||
    die "jq non è installato. Esegui scripts/installer.sh."

  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "repository non valido: usa il formato OWNER/REPOSITORY."
  [[ -f "$json_file" ]] ||
    die "file JSON non trovato: $json_file"
  jq empty "$json_file" >/dev/null 2>&1 ||
    die "JSON non valido: $json_file"
  jq -e '.labels | type == "array"' "$json_file" >/dev/null ||
    die "il campo 'labels' deve essere un array."

  # Valida tutte le label prima di effettuare qualsiasi modifica remota.
  while IFS= read -r label; do
    id="$(jq -r '.id // empty' <<<"$label")"
    name="$(jq -r '.name // empty' <<<"$label")"
    color="$(jq -r '.color // empty | tostring' <<<"$label")"

    [[ -n "$id" ]] ||
      die "una label non contiene il campo obbligatorio 'id'."
    [[ -n "$name" ]] ||
      die "la label '$id' non contiene il campo obbligatorio 'name'."
    [[ "$color" =~ ^[0-9A-Fa-f]{6}$ ]] ||
      die "la label '$id' ha un colore non valido: '$color'."

    normalized_name="${name,,}"
    [[ -z "${configured_names[$normalized_name]+present}" ]] ||
      die "nome label duplicato nella configurazione: '$name'."
    configured_names["$normalized_name"]=1
  done < <(jq -c '.labels[]' "$json_file")
}

sync_labels() {
  local repository="$1"
  local json_file="$2"
  local remote_labels label existing
  local name color description
  local existing_name existing_color existing_description
  local created=0 updated=0 unchanged=0

  "$SCRIPT_DIR/auth.sh" "$repository" write

  remote_labels="$(
    gh label list \
      --repo "$repository" \
      --limit 1000 \
      --json name,color,description
  )" || die "impossibile leggere le label del repository '$repository'."

  while IFS= read -r label; do
    name="$(jq -r '.name' <<<"$label")"
    color="$(jq -r '.color | ascii_upcase' <<<"$label")"
    description="$(jq -r '.description // ""' <<<"$label")"

    existing="$(
      jq -c --arg name "$name" \
        '[.[] | select((.name | ascii_downcase) == ($name | ascii_downcase))][0] // empty' \
        <<<"$remote_labels"
    )"

    if [[ -z "$existing" ]]; then
      log "Creazione label: $name"
      gh label create "$name" \
        --repo "$repository" \
        --color "$color" \
        --description "$description" >/dev/null
      ((created += 1))
      continue
    fi

    existing_name="$(jq -r '.name' <<<"$existing")"
    existing_color="$(jq -r '.color | ascii_upcase' <<<"$existing")"
    existing_description="$(jq -r '.description // ""' <<<"$existing")"

    if [[ "$existing_name" == "$name" &&
      "$existing_color" == "$color" &&
      "$existing_description" == "$description" ]]; then
      log "Label invariata: $name"
      ((unchanged += 1))
      continue
    fi

    log "Aggiornamento label: $existing_name"
    gh label edit "$existing_name" \
      --repo "$repository" \
      --name "$name" \
      --color "$color" \
      --description "$description" >/dev/null
    ((updated += 1))
  done < <(jq -c '.labels[]' "$json_file")

  log "Sincronizzazione completata: create=$created, aggiornate=$updated, invariate=$unchanged."
}

main() {
  if (($# >= 1)); then
    case "$1" in
      -h | --help)
        usage
        return
        ;;
    esac
  fi

  if (($# != 2)); then
    usage >&2
    return 2
  fi

  validate_inputs "$1" "$2"
  sync_labels "$1" "$2"
}

main "$@"
