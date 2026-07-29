#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
ERROR_COUNT=0

log() {
  printf '[%s] %s\n' "$PROGRAM_NAME" "$*"
}

error() {
  printf '[%s] Errore: %s\n' "$PROGRAM_NAME" "$*" >&2
  ((ERROR_COUNT += 1))
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    error "il comando '$1' non è installato."
    return 1
  }
}

is_valid_id() {
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

validate_config() {
  local json_file="$1"
  local item id name title color due_on state reference
  local labels_valid=false milestones_valid=false issues_valid=false
  local -A label_ids=()
  local -A milestone_ids=()
  local -A issue_ids=()

  require_command jq || return 1

  [[ -f "$json_file" ]] || {
    error "file JSON non trovato: $json_file"
    return 1
  }

  if ! jq empty "$json_file" >/dev/null 2>&1; then
    error "JSON non valido: $json_file"
    return 1
  fi

  jq -e '.version | type == "number"' "$json_file" >/dev/null ||
    error "il campo 'version' deve essere un numero."
  jq -e '.repository | type == "object"' "$json_file" >/dev/null ||
    error "il campo 'repository' deve essere un oggetto."

  if jq -e '.labels | type == "array"' "$json_file" >/dev/null; then
    labels_valid=true
  else
    error "il campo 'labels' deve essere un array."
  fi

  if jq -e '.milestones | type == "array"' "$json_file" >/dev/null; then
    milestones_valid=true
  else
    error "il campo 'milestones' deve essere un array."
  fi

  if jq -e '.issues | type == "array"' "$json_file" >/dev/null; then
    issues_valid=true
  else
    error "il campo 'issues' deve essere un array."
  fi

  if [[ "$labels_valid" == true ]]; then
    while IFS= read -r item; do
      id="$(jq -r '.id // empty' <<<"$item")"
      name="$(jq -r '.name // empty' <<<"$item")"
      color="$(jq -r '.color // empty | tostring' <<<"$item")"

      [[ -n "$id" ]] || {
        error "una label non contiene il campo obbligatorio 'id'."
        continue
      }
      is_valid_id "$id" ||
        error "la label '$id' ha un ID non valido."
      [[ -z "${label_ids[$id]+present}" ]] ||
        error "ID label duplicato: '$id'."
      label_ids["$id"]=1

      [[ -n "$name" ]] ||
        error "la label '$id' non contiene il campo obbligatorio 'name'."
      [[ "$color" =~ ^[0-9A-Fa-f]{6}$ ]] ||
        error "la label '$id' ha un colore non valido: '$color'."
    done < <(jq -c '.labels[]' "$json_file")
  fi

  if [[ "$milestones_valid" == true ]]; then
    while IFS= read -r item; do
      id="$(jq -r '.id // empty' <<<"$item")"
      title="$(jq -r '.title // empty' <<<"$item")"
      due_on="$(jq -r '.due_on // empty | tostring' <<<"$item")"
      state="$(jq -r '.state // empty' <<<"$item")"

      [[ -n "$id" ]] || {
        error "una milestone non contiene il campo obbligatorio 'id'."
        continue
      }
      is_valid_id "$id" ||
        error "la milestone '$id' ha un ID non valido."
      [[ -z "${milestone_ids[$id]+present}" ]] ||
        error "ID milestone duplicato: '$id'."
      milestone_ids["$id"]=1

      [[ -n "$title" ]] ||
        error "la milestone '$id' non contiene il campo obbligatorio 'title'."
      [[ -z "$due_on" || "$due_on" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
        error "la milestone '$id' ha una data non valida: '$due_on'."
      [[ -z "$state" || "$state" == "open" || "$state" == "closed" ]] ||
        error "la milestone '$id' ha uno stato non valido: '$state'."
    done < <(jq -c '.milestones[]' "$json_file")
  fi

  if [[ "$issues_valid" == true ]]; then
    while IFS= read -r item; do
      id="$(jq -r '.id // empty' <<<"$item")"

      [[ -n "$id" ]] || {
        error "una issue non contiene il campo obbligatorio 'id'."
        continue
      }
      is_valid_id "$id" ||
        error "la issue '$id' ha un ID non valido."
      [[ -z "${issue_ids[$id]+present}" ]] ||
        error "ID issue duplicato: '$id'."
      issue_ids["$id"]=1
    done < <(jq -c '.issues[]' "$json_file")

    while IFS= read -r item; do
      id="$(jq -r '.id // "<senza-id>"' <<<"$item")"
      title="$(jq -r '.title // empty' <<<"$item")"
      state="$(jq -r '.state // empty' <<<"$item")"

      [[ -n "$title" ]] ||
        error "la issue '$id' non contiene il campo obbligatorio 'title'."
      [[ -z "$state" || "$state" == "open" || "$state" == "closed" ]] ||
        error "la issue '$id' ha uno stato non valido: '$state'."

      if ! jq -e '(.labels // []) | type == "array"' <<<"$item" >/dev/null; then
        error "il campo 'labels' della issue '$id' deve essere un array."
      else
        while IFS= read -r reference; do
          [[ -n "${label_ids[$reference]+present}" ]] ||
            error "la issue '$id' fa riferimento alla label inesistente '$reference'."
        done < <(jq -r '.labels[]? | tostring' <<<"$item")
      fi

      reference="$(jq -r '.milestone // empty | tostring' <<<"$item")"
      if [[ -n "$reference" && -z "${milestone_ids[$reference]+present}" ]]; then
        error "la issue '$id' fa riferimento alla milestone inesistente '$reference'."
      fi

      if ! jq -e '(.dependencies // []) | type == "array"' \
        <<<"$item" >/dev/null; then
        error "il campo 'dependencies' della issue '$id' deve essere un array."
      else
        while IFS= read -r reference; do
          [[ -n "${issue_ids[$reference]+present}" ]] ||
            error "la issue '$id' dipende dalla issue inesistente '$reference'."
          [[ "$reference" != "$id" ]] ||
            error "la issue '$id' non può dipendere da sé stessa."
        done < <(jq -r '.dependencies[]? | tostring' <<<"$item")
      fi
    done < <(jq -c '.issues[]' "$json_file")
  fi

  if ((ERROR_COUNT > 0)); then
    printf '[%s] Validazione fallita: %d errori.\n' \
      "$PROGRAM_NAME" "$ERROR_COUNT" >&2
    return 1
  fi

  log "Configurazione valida: $json_file"
}

main() {
  if (($# != 1)); then
    printf 'Uso: %s FILE_JSON\n' "$PROGRAM_NAME" >&2
    return 2
  fi

  validate_config "$1"
}

main "$@"
