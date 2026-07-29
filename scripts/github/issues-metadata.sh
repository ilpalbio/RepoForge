#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly API_VERSION="2026-03-10"

source "$SCRIPT_DIR/../log/log.sh"

usage() {
  cat <<EOF
Uso: $PROGRAM_NAME OWNER/REPOSITORY FILE_JSON

Sincronizza stato, assegnatari e dipendenze delle issue già create su GitHub.
Le dipendenze remote non dichiarate nel JSON vengono rimosse.
EOF
}

validate_inputs() {
  local repository="$1"
  local json_file="$2"

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
  jq -e \
    '(.issues | type == "array")
     and all(.issues[];
       (.id | type == "string")
       and (.title | type == "string")
       and ((.state // "open") | IN("open", "closed"))
       and ((.assignees // []) | type == "array")
       and ((.dependencies // []) | type == "array")
     )' "$json_file" >/dev/null ||
    die "la configurazione delle issue non è valida."
}

sync_issue_metadata() {
  local repository="$1"
  local json_file="$2"
  local remote_issues issue existing marker
  local id title number database_id state
  local desired_assignees current_assignees
  local dependency_id dependency_database_id
  local current_dependencies current_dependency_ids desired_dependency_ids
  local added_ids removed_ids relation_id
  local metadata_updated=0 dependencies_added=0 dependencies_removed=0 unchanged=0
  local -A issue_numbers=()
  local -A issue_database_ids=()

  "$SCRIPT_DIR/auth.sh" "$repository" write

  remote_issues="$(
    gh issue list \
      --repo "$repository" \
      --state all \
      --limit 1000 \
      --json number,title,body,state,assignees
  )" || die "impossibile leggere le issue del repository '$repository'."

  # Risolve tutti gli ID prima di modificare GitHub, evitando applicazioni parziali.
  while IFS= read -r issue; do
    id="$(jq -r '.id' <<<"$issue")"
    title="$(jq -r '.title' <<<"$issue")"
    marker="<!-- repoforge:id=$id -->"

    existing="$(
      jq -c --arg marker "$marker" --arg title "$title" \
        '(
          [.[] | select((.body // "") | contains($marker))][0]
          // [.[] | select((.title | ascii_downcase) == ($title | ascii_downcase))][0]
          // empty
        )' <<<"$remote_issues"
    )"
    [[ -n "$existing" ]] ||
      die "issue '$id' non presente su GitHub: sincronizza prima le issue."

    number="$(jq -r '.number' <<<"$existing")"
    database_id="$(
      gh api \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "repos/$repository/issues/$number" \
        --jq '.id'
    )" || die "impossibile risolvere l'ID GitHub della issue '#$number'."

    issue_numbers["$id"]="$number"
    issue_database_ids["$id"]="$database_id"
  done < <(jq -c '.issues[]' "$json_file")

  while IFS= read -r issue; do
    id="$(jq -r '.id' <<<"$issue")"
    number="${issue_numbers[$id]}"
    state="$(jq -r '.state // "open"' <<<"$issue")"
    desired_assignees="$(
      jq -c '[.assignees[]? | ascii_downcase] | sort' <<<"$issue"
    )"
    existing="$(
      jq -c --argjson number "$number" \
        '[.[] | select(.number == $number)][0]' <<<"$remote_issues"
    )"
    current_assignees="$(
      jq -c '[.assignees[].login | ascii_downcase] | sort' <<<"$existing"
    )"

    if [[ "$(jq -r '.state | ascii_downcase' <<<"$existing")" != "$state" ||
      "$current_assignees" != "$desired_assignees" ]]; then
      log "Aggiornamento stato/assegnatari: #$number $id"
      jq -n \
        --arg state "$state" \
        --argjson assignees "$(jq -c '.assignees // []' <<<"$issue")" \
        '{state: $state, assignees: $assignees}' |
        gh api --method PATCH \
          -H "X-GitHub-Api-Version: $API_VERSION" \
          "repos/$repository/issues/$number" \
          --input - >/dev/null
      ((metadata_updated += 1))
    fi

    desired_dependency_ids='[]'
    while IFS= read -r dependency_id; do
      [[ -n "${issue_database_ids[$dependency_id]+present}" ]] ||
        die "la issue '$id' dipende dall'ID inesistente '$dependency_id'."
      dependency_database_id="${issue_database_ids[$dependency_id]}"
      desired_dependency_ids="$(
        jq -c --argjson value "$dependency_database_id" \
          '. + [$value]' <<<"$desired_dependency_ids"
      )"
    done < <(jq -r '.dependencies[]?' <<<"$issue")
    desired_dependency_ids="$(jq -c 'unique | sort' <<<"$desired_dependency_ids")"

    current_dependencies="$(
      gh api --paginate \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "repos/$repository/issues/$number/dependencies/blocked_by?per_page=100" |
        jq -s 'add // []'
    )" || die "impossibile leggere le dipendenze della issue '#$number'."
    current_dependency_ids="$(
      jq -c '[.[].id] | unique | sort' <<<"$current_dependencies"
    )"

    added_ids="$(
      jq -cn \
        --argjson desired "$desired_dependency_ids" \
        --argjson current "$current_dependency_ids" \
        '$desired - $current'
    )"
    removed_ids="$(
      jq -cn \
        --argjson desired "$desired_dependency_ids" \
        --argjson current "$current_dependency_ids" \
        '$current - $desired'
    )"

    while IFS= read -r relation_id; do
      log "Aggiunta dipendenza alla issue #$number: issue_id=$relation_id"
      jq -n --argjson issue_id "$relation_id" '{issue_id: $issue_id}' |
        gh api --method POST \
          -H "X-GitHub-Api-Version: $API_VERSION" \
          "repos/$repository/issues/$number/dependencies/blocked_by" \
          --input - >/dev/null
      ((dependencies_added += 1))
    done < <(jq -r '.[]' <<<"$added_ids")

    while IFS= read -r relation_id; do
      log "Rimozione dipendenza dalla issue #$number: issue_id=$relation_id"
      gh api --method DELETE \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "repos/$repository/issues/$number/dependencies/blocked_by/$relation_id" \
        >/dev/null
      ((dependencies_removed += 1))
    done < <(jq -r '.[]' <<<"$removed_ids")

    if [[ "$(jq 'length' <<<"$added_ids")" == "0" &&
      "$(jq 'length' <<<"$removed_ids")" == "0" &&
      "$(jq -r '.state | ascii_downcase' <<<"$existing")" == "$state" &&
      "$current_assignees" == "$desired_assignees" ]]; then
      log "Metadati invariati: #$number $id"
      ((unchanged += 1))
    fi
  done < <(jq -c '.issues[]' "$json_file")

  log "Sincronizzazione completata: metadati_aggiornati=$metadata_updated, dipendenze_aggiunte=$dependencies_added, dipendenze_rimosse=$dependencies_removed, invariate=$unchanged."
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
  sync_issue_metadata "$1" "$2"
}

main "$@"
