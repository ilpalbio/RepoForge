#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source "$SCRIPT_DIR/../log/log.sh"

usage() {
  cat <<EOF
Uso: $PROGRAM_NAME OWNER/REPOSITORY FILE_JSON

Sincronizza le issue definite in FILE_JSON con il repository GitHub.
Le issue non presenti nella configurazione non vengono chiuse o eliminate.
EOF
}

validate_inputs() {
  local repository="$1"
  local json_file="$2"
  local issue id title state
  local -A configured_ids=()

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
    '(.issues | type == "array")
     and (.labels | type == "array")
     and (.milestones | type == "array")' \
    "$json_file" >/dev/null ||
    die "i campi 'issues', 'labels' e 'milestones' devono essere array."

  # Valida tutte le issue prima di effettuare modifiche remote.
  while IFS= read -r issue; do
    id="$(jq -r '.id // empty' <<<"$issue")"
    title="$(jq -r '.title // empty' <<<"$issue")"
    state="$(jq -r '.state // "open"' <<<"$issue")"

    [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
      die "ID issue non valido: '$id'."
    [[ -n "$title" ]] ||
      die "la issue '$id' non contiene il campo obbligatorio 'title'."
    [[ "$state" == "open" || "$state" == "closed" ]] ||
      die "la issue '$id' ha uno stato non valido: '$state'."
    jq -e '(.labels // []) | type == "array"' <<<"$issue" >/dev/null ||
      die "il campo 'labels' della issue '$id' deve essere un array."
    jq -e '(.assignees // []) | type == "array"' <<<"$issue" >/dev/null ||
      die "il campo 'assignees' della issue '$id' deve essere un array."

    [[ -z "${configured_ids[$id]+present}" ]] ||
      die "ID issue duplicato: '$id'."
    configured_ids["$id"]=1
  done < <(jq -c '.issues[]' "$json_file")
}

issue_payload() {
  local title="$1"
  local body="$2"
  local state="$3"
  local labels_json="$4"
  local assignees_json="$5"
  local milestone_number="$6"

  jq -n \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --argjson labels "$labels_json" \
    --argjson assignees "$assignees_json" \
    --argjson milestone "$milestone_number" \
    '{
      title: $title,
      body: $body,
      state: $state,
      labels: $labels,
      assignees: $assignees,
      milestone: $milestone
    }'
}

configured_label_names() {
  local json_file="$1"
  local issue="$2"
  local references

  references="$(jq -c '.labels // []' <<<"$issue")"
  jq -c --argjson references "$references" \
    '[.labels[] | select(.id as $id | $references | index($id)) | .name]' \
    "$json_file"
}

remote_milestone_number() {
  local json_file="$1"
  local remote_milestones="$2"
  local milestone_id="$3"
  local milestone_title marker number

  [[ -n "$milestone_id" ]] || {
    printf 'null\n'
    return
  }

  milestone_title="$(
    jq -r --arg id "$milestone_id" \
      '.milestones[] | select(.id == $id) | .title' "$json_file"
  )"
  [[ -n "$milestone_title" ]] ||
    die "milestone '$milestone_id' non definita nella configurazione."

  marker="<!-- repoforge:id=$milestone_id -->"
  number="$(
    jq -r --arg marker "$marker" --arg title "$milestone_title" \
      '(
        [.[] | select((.description // "") | contains($marker))][0]
        // [.[] | select((.title | ascii_downcase) == ($title | ascii_downcase))][0]
        // empty
      ) | .number' <<<"$remote_milestones"
  )"
  [[ -n "$number" ]] ||
    die "milestone '$milestone_title' non presente su GitHub: sincronizza prima le milestone."
  printf '%s\n' "$number"
}

verify_remote_references() {
  local json_file="$1"
  local remote_labels="$2"
  local remote_milestones="$3"
  local name id

  while IFS= read -r name; do
    jq -e --arg name "$name" \
      'any(.[]; (.name | ascii_downcase) == ($name | ascii_downcase))' \
      <<<"$remote_labels" >/dev/null ||
      die "label '$name' non presente su GitHub: sincronizza prima le label."
  done < <(jq -r '[.issues[].labels[]?] as $used |
    .labels[] | select(.id as $id | $used | index($id)) | .name' "$json_file")

  while IFS= read -r id; do
    remote_milestone_number \
      "$json_file" "$remote_milestones" "$id" >/dev/null
  done < <(jq -r '[.issues[].milestone? | select(. != null)] | unique[]' "$json_file")
}

sync_issues() {
  local repository="$1"
  local json_file="$2"
  local remote_issues remote_labels remote_milestones
  local issue existing marker id title body managed_body state
  local labels_json assignees_json milestone_id milestone_number
  local number created_issue desired_signature existing_signature
  local created=0 updated=0 unchanged=0

  "$SCRIPT_DIR/auth.sh" "$repository" write

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
      --json number,title,body,state,labels,assignees,milestone
  )" || die "impossibile leggere le issue del repository '$repository'."

  verify_remote_references "$json_file" "$remote_labels" "$remote_milestones"
  log "Issue remote rilevate: $(jq 'length' <<<"$remote_issues")"

  while IFS= read -r issue; do
    id="$(jq -r '.id' <<<"$issue")"
    title="$(jq -r '.title' <<<"$issue")"
    body="$(jq -r '.body // .description // ""' <<<"$issue")"
    state="$(jq -r '.state // "open"' <<<"$issue")"
    labels_json="$(configured_label_names "$json_file" "$issue")"
    assignees_json="$(jq -c '.assignees // []' <<<"$issue")"
    milestone_id="$(jq -r '.milestone // empty' <<<"$issue")"
    milestone_number="$(
      remote_milestone_number \
        "$json_file" "$remote_milestones" "$milestone_id"
    )"
    marker="<!-- repoforge:id=$id -->"

    managed_body="$body"
    [[ -z "$managed_body" ]] ||
      managed_body+=$'\n\n'
    managed_body+="$marker"

    existing="$(
      jq -c --arg marker "$marker" \
        '[.[] | select((.body // "") | contains($marker))][0] // empty' \
        <<<"$remote_issues"
    )"

    # Adotta una issue preesistente con lo stesso titolo aggiungendo il marker.
    if [[ -z "$existing" ]]; then
      existing="$(
        jq -c --arg title "$title" \
          '[.[] | select((.title | ascii_downcase) == ($title | ascii_downcase))][0] // empty' \
          <<<"$remote_issues"
      )"
    fi

    if [[ -z "$existing" ]]; then
      log "Creazione issue: $title"
      created_issue="$(
        issue_payload \
          "$title" "$managed_body" "$state" \
          "$labels_json" "$assignees_json" "$milestone_number" |
          jq 'del(.state)' |
          gh api --method POST \
            "repos/$repository/issues" \
            --input -
      )"

      # L'API di creazione apre sempre la issue; la chiude subito se richiesto.
      if [[ "$state" == "closed" ]]; then
        number="$(jq -r '.number' <<<"$created_issue")"
        issue_payload \
          "$title" "$managed_body" "$state" \
          "$labels_json" "$assignees_json" "$milestone_number" |
          gh api --method PATCH \
            "repos/$repository/issues/$number" \
            --input - >/dev/null
      fi
      ((created += 1))
      continue
    fi

    number="$(jq -r '.number' <<<"$existing")"
    desired_signature="$(
      jq -cn \
        --arg title "$title" \
        --arg body "$managed_body" \
        --arg state "$state" \
        --argjson labels "$labels_json" \
        --argjson assignees "$assignees_json" \
        --argjson milestone "$milestone_number" \
        '{
          title: $title,
          body: $body,
          state: $state,
          labels: ($labels | map(ascii_downcase) | sort),
          assignees: ($assignees | map(ascii_downcase) | sort),
          milestone: $milestone
        }'
    )"
    existing_signature="$(
      jq -c '{
        title,
        body: (.body // ""),
        state: (.state | ascii_downcase),
        labels: ([.labels[].name | ascii_downcase] | sort),
        assignees: ([.assignees[].login | ascii_downcase] | sort),
        milestone: (.milestone.number // null)
      }' <<<"$existing"
    )"

    if [[ "$existing_signature" == "$desired_signature" ]]; then
      log "Issue invariata: #$number $title"
      ((unchanged += 1))
      continue
    fi

    log "Aggiornamento issue: #$number $title"
    issue_payload \
      "$title" "$managed_body" "$state" \
      "$labels_json" "$assignees_json" "$milestone_number" |
      gh api --method PATCH \
        "repos/$repository/issues/$number" \
        --input - >/dev/null
    ((updated += 1))
  done < <(jq -c '.issues[]' "$json_file")

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
  sync_issues "$1" "$2"
}

main "$@"
