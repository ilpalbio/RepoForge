#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source "$SCRIPT_DIR/../log/log.sh"

usage() {
  cat <<EOF
Uso: $PROGRAM_NAME OWNER/REPOSITORY FILE_JSON

Sincronizza le milestone definite in FILE_JSON con il repository GitHub.
Le milestone non presenti nella configurazione non vengono eliminate.
EOF
}

validate_inputs() {
  local repository="$1"
  local json_file="$2"
  local milestone id title due_on state normalized_title
  local -A configured_ids=()
  local -A configured_titles=()

  command -v gh >/dev/null 2>&1 ||
    die "GitHub CLI non è installato. Esegui: ./repoforge.sh install"
  command -v jq >/dev/null 2>&1 ||
    die "jq non è installato. Esegui: ./repoforge.sh install"

  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "repository non valido: usa il formato OWNER/REPOSITORY."
  [[ -f "$json_file" ]] ||
    die "file JSON non trovato: $json_file"
  jq empty "$json_file" >/dev/null 2>&1 ||
    die "JSON non valido: $json_file"
  jq -e '.milestones | type == "array"' "$json_file" >/dev/null ||
    die "il campo 'milestones' deve essere un array."

  # Valida l'intera configurazione prima di modificare il repository.
  while IFS= read -r milestone; do
    id="$(jq -r '.id // empty' <<<"$milestone")"
    title="$(jq -r '.title // empty' <<<"$milestone")"
    due_on="$(jq -r '.due_on // empty | tostring' <<<"$milestone")"
    state="$(jq -r '.state // "open"' <<<"$milestone")"

    [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
      die "ID milestone non valido: '$id'."
    [[ -n "$title" ]] ||
      die "la milestone '$id' non contiene il campo obbligatorio 'title'."
    [[ -z "$due_on" || "$due_on" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
      die "la milestone '$id' ha una data non valida: '$due_on'."
    [[ "$state" == "open" || "$state" == "closed" ]] ||
      die "la milestone '$id' ha uno stato non valido: '$state'."

    [[ -z "${configured_ids[$id]+present}" ]] ||
      die "ID milestone duplicato: '$id'."
    configured_ids["$id"]=1

    normalized_title="${title,,}"
    [[ -z "${configured_titles[$normalized_title]+present}" ]] ||
      die "titolo milestone duplicato: '$title'."
    configured_titles["$normalized_title"]=1
  done < <(jq -c '.milestones[]' "$json_file")
}

milestone_payload() {
  local title="$1"
  local description="$2"
  local due_on="$3"
  local state="$4"

  jq -n \
    --arg title "$title" \
    --arg description "$description" \
    --arg due_on "$due_on" \
    --arg state "$state" \
    '{
      title: $title,
      description: $description,
      state: $state
    }
    + (
      if $due_on == ""
      then {}
      else {due_on: ($due_on + "T23:59:59Z")}
      end
    )'
}

sync_milestones() {
  local repository="$1"
  local json_file="$2"
  local remote_milestones milestone existing marker
  local id title description managed_description due_on state
  local number existing_title existing_description existing_due_on existing_state
  local created=0 updated=0 unchanged=0

  "$SCRIPT_DIR/auth.sh" "$repository" write

  remote_milestones="$(
    gh api --paginate \
      "repos/$repository/milestones?state=all&per_page=100" |
      jq -s 'add // []'
  )" || die "impossibile leggere le milestone del repository '$repository'."

  while IFS= read -r milestone; do
    id="$(jq -r '.id' <<<"$milestone")"
    title="$(jq -r '.title' <<<"$milestone")"
    description="$(jq -r '.description // ""' <<<"$milestone")"
    due_on="$(jq -r '.due_on // empty | tostring' <<<"$milestone")"
    state="$(jq -r '.state // "open"' <<<"$milestone")"
    marker="<!-- repoforge:id=$id -->"

    managed_description="$description"
    [[ -z "$managed_description" ]] ||
      managed_description+=$'\n\n'
    managed_description+="$marker"

    existing="$(
      jq -c --arg marker "$marker" \
        '[.[] | select((.description // "") | contains($marker))][0] // empty' \
        <<<"$remote_milestones"
    )"

    # Adotta una milestone preesistente con lo stesso titolo aggiungendo il marker.
    if [[ -z "$existing" ]]; then
      existing="$(
        jq -c --arg title "$title" \
          '[.[] | select((.title | ascii_downcase) == ($title | ascii_downcase))][0] // empty' \
          <<<"$remote_milestones"
      )"
    fi

    if [[ -z "$existing" ]]; then
      log "Creazione milestone: $title"
      milestone_payload \
        "$title" "$managed_description" "$due_on" "$state" |
        gh api --method POST \
          "repos/$repository/milestones" \
          --input - >/dev/null
      ((created += 1))
      continue
    fi

    number="$(jq -r '.number' <<<"$existing")"
    existing_title="$(jq -r '.title' <<<"$existing")"
    existing_description="$(jq -r '.description // ""' <<<"$existing")"
    existing_due_on="$(jq -r '.due_on // "" | .[0:10]' <<<"$existing")"
    existing_state="$(jq -r '.state' <<<"$existing")"

    if [[ "$existing_title" == "$title" &&
      "$existing_description" == "$managed_description" &&
      "$existing_due_on" == "$due_on" &&
      "$existing_state" == "$state" ]]; then
      log "Milestone invariata: $title"
      ((unchanged += 1))
      continue
    fi

    log "Aggiornamento milestone: $existing_title"
    milestone_payload \
      "$title" "$managed_description" "$due_on" "$state" |
      gh api --method PATCH \
        "repos/$repository/milestones/$number" \
        --input - >/dev/null
    ((updated += 1))
  done < <(jq -c '.milestones[]' "$json_file")

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
  sync_milestones "$1" "$2"
}

main "$@"
