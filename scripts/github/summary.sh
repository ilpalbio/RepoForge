#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source "$SCRIPT_DIR/../log/log.sh"

usage() {
  cat <<EOF
Uso: $PROGRAM_NAME OWNER/REPOSITORY FILE_JSON

Mostra il riepilogo finale della configurazione sincronizzata con GitHub.
Il comando è in sola lettura e non modifica il repository.
EOF
}

validate_inputs() {
  local repository="$1"
  local json_file="$2"

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
  jq -e \
    '(.labels | type == "array")
     and (.milestones | type == "array")
     and (.issues | type == "array")' \
    "$json_file" >/dev/null ||
    die "i campi 'labels', 'milestones' e 'issues' devono essere array."
}

print_row() {
  printf '  %-24s %s\n' "$1" "$2"
}

show_summary() {
  local repository="$1"
  local json_file="$2"
  local remote_labels remote_milestones remote_issues
  local configured_labels configured_milestones configured_issues
  local matched_labels=0 matched_milestones=0 matched_issues=0
  local open_issues closed_issues assignments dependencies
  local item id name title marker
  local -a missing_labels=()
  local -a missing_milestones=()
  local -a missing_issues=()

  "$SCRIPT_DIR/auth.sh" "$repository" read

  remote_labels="$(
    gh label list \
      --repo "$repository" \
      --limit 1000 \
      --json name,color,description
  )" || die "impossibile leggere le label del repository '$repository'."

  remote_milestones="$(
    gh api --paginate \
      "repos/$repository/milestones?state=all&per_page=100" |
      jq -s 'add // []'
  )" || die "impossibile leggere le milestone del repository '$repository'."

  remote_issues="$(
    gh issue list \
      --repo "$repository" \
      --state all \
      --limit 1000 \
      --json number,title,body,state,assignees,milestone
  )" || die "impossibile leggere le issue del repository '$repository'."

  configured_labels="$(jq '.labels | length' "$json_file")"
  configured_milestones="$(jq '.milestones | length' "$json_file")"
  configured_issues="$(jq '.issues | length' "$json_file")"
  open_issues="$(jq '[.issues[] | select((.state // "open") == "open")] | length' "$json_file")"
  closed_issues="$(jq '[.issues[] | select(.state == "closed")] | length' "$json_file")"
  assignments="$(jq '[.issues[].assignees[]?] | length' "$json_file")"
  dependencies="$(jq '[.issues[].dependencies[]?] | length' "$json_file")"

  while IFS= read -r item; do
    name="$(jq -r '.name' <<<"$item")"
    if jq -e --arg name "$name" \
      'any(.[]; (.name | ascii_downcase) == ($name | ascii_downcase))' \
      <<<"$remote_labels" >/dev/null; then
      ((matched_labels += 1))
    else
      missing_labels+=("$name")
    fi
  done < <(jq -c '.labels[]' "$json_file")

  while IFS= read -r item; do
    id="$(jq -r '.id' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    marker="<!-- repoforge:id=$id -->"
    if jq -e --arg marker "$marker" --arg title "$title" \
      'any(.[];
        ((.description // "") | contains($marker))
        or ((.title | ascii_downcase) == ($title | ascii_downcase))
      )' <<<"$remote_milestones" >/dev/null; then
      ((matched_milestones += 1))
    else
      missing_milestones+=("$title")
    fi
  done < <(jq -c '.milestones[]' "$json_file")

  while IFS= read -r item; do
    id="$(jq -r '.id' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    marker="<!-- repoforge:id=$id -->"
    if jq -e --arg marker "$marker" --arg title "$title" \
      'any(.[];
        ((.body // "") | contains($marker))
        or ((.title | ascii_downcase) == ($title | ascii_downcase))
      )' <<<"$remote_issues" >/dev/null; then
      ((matched_issues += 1))
    else
      missing_issues+=("$title")
    fi
  done < <(jq -c '.issues[]' "$json_file")

  printf '\nRiepilogo RepoForge\n'
  printf '===================\n'
  print_row "Repository" "$repository"
  print_row "Label sincronizzate" "$matched_labels/$configured_labels"
  print_row "Milestone sincronizzate" "$matched_milestones/$configured_milestones"
  print_row "Issue sincronizzate" "$matched_issues/$configured_issues"
  print_row "Issue aperte" "$open_issues"
  print_row "Issue chiuse" "$closed_issues"
  print_row "Assegnazioni dichiarate" "$assignments"
  print_row "Dipendenze dichiarate" "$dependencies"

  if ((${#missing_labels[@]} > 0)); then
    printf '\nLabel mancanti:\n'
    printf '  - %s\n' "${missing_labels[@]}"
  fi
  if ((${#missing_milestones[@]} > 0)); then
    printf '\nMilestone mancanti:\n'
    printf '  - %s\n' "${missing_milestones[@]}"
  fi
  if ((${#missing_issues[@]} > 0)); then
    printf '\nIssue mancanti:\n'
    printf '  - %s\n' "${missing_issues[@]}"
  fi

  if ((${#missing_labels[@]} > 0 ||
    ${#missing_milestones[@]} > 0 ||
    ${#missing_issues[@]} > 0)); then
    die "sincronizzazione incompleta."
  fi

  printf '\n'
  log "Sincronizzazione completa."
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
  show_summary "$1" "$2"
}

main "$@"
