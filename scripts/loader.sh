#!/usr/bin/env bash

# Questo file può essere eseguito direttamente oppure importato con `source`.

loader_log() {
  printf '[loader.sh] %s\n' "$*" >&2
}

loader_die() {
  printf '[loader.sh] Errore: %s\n' "$*" >&2
  return 1
}

loader_require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    loader_die "il comando '$1' non è installato."
}

loader_yaml_type() {
  local expression="$1"
  local file="$2"
  yq eval -r "$expression | type" "$file"
}

load_repoforge_config() {
  local manifest="${1:-repoforge.yaml}"
  local manifest_dir manifest_file work_dir merged_file next_file fragment_file
  local source_name source_type pattern source_file
  local -a source_names=()
  local -a patterns=()
  local -a matches=()

  loader_require_command yq || return 1

  [[ -f "$manifest" ]] ||
    loader_die "manifest non trovato: $manifest" || return 1

  manifest_dir="$(cd -- "$(dirname -- "$manifest")" && pwd -P)" || return 1
  manifest_file="$manifest_dir/$(basename -- "$manifest")"

  if ! yq eval '.' "$manifest_file" >/dev/null; then
    loader_die "sintassi YAML non valida nel manifest: $manifest_file"
    return 1
  fi

  [[ "$(loader_yaml_type '.version' "$manifest_file")" == "!!int" ]] ||
    loader_die "il campo 'version' deve essere un intero." || return 1
  [[ "$(loader_yaml_type '.repository' "$manifest_file")" == "!!map" ]] ||
    loader_die "il campo 'repository' deve essere una mappa." || return 1
  [[ "$(loader_yaml_type '.sources' "$manifest_file")" == "!!map" ]] ||
    loader_die "il campo 'sources' deve essere una mappa." || return 1

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/repoforge-loader.XXXXXXXX")" ||
    return 1
  merged_file="$work_dir/merged.json"
  next_file="$work_dir/next.json"
  fragment_file="$work_dir/fragment.json"

  if ! yq eval -o=json 'del(.sources)' "$manifest_file" >"$merged_file"; then
    loader_die "impossibile convertire il manifest."
    rm -f -- "$merged_file" "$next_file" "$fragment_file"
    rmdir -- "$work_dir" 2>/dev/null || true
    return 1
  fi

  mapfile -t source_names < <(yq eval -r '.sources | keys | .[]' "$manifest_file")

  for source_name in "${source_names[@]}"; do
    export SOURCE_NAME="$source_name"
    source_type="$(
      yq eval -r '.sources[strenv(SOURCE_NAME)] | type' "$manifest_file"
    )"
    patterns=()

    case "$source_type" in
      '!!str')
        mapfile -t patterns < <(
          yq eval -r '.sources[strenv(SOURCE_NAME)]' "$manifest_file"
        )
        ;;
      '!!seq')
        mapfile -t patterns < <(
          yq eval -r '.sources[strenv(SOURCE_NAME)][]' "$manifest_file"
        )
        ;;
      *)
        loader_die "la source '$source_name' deve essere un percorso o una lista."
        rm -f -- "$merged_file" "$next_file"
        rmdir -- "$work_dir" 2>/dev/null || true
        return 1
        ;;
    esac

    ((${#patterns[@]} > 0)) || {
      loader_die "la source '$source_name' non contiene percorsi."
      rm -f -- "$merged_file" "$next_file"
      rmdir -- "$work_dir" 2>/dev/null || true
      return 1
    }

    for pattern in "${patterns[@]}"; do
      [[ "$pattern" != /* ]] || {
        loader_die "il percorso '$pattern' deve essere relativo al manifest."
        rm -f -- "$merged_file" "$next_file"
        rmdir -- "$work_dir" 2>/dev/null || true
        return 1
      }

      matches=()
      mapfile -t matches < <(compgen -G "$manifest_dir/$pattern" || true)
      ((${#matches[@]} > 0)) || {
        loader_die "nessun file corrisponde a '$pattern' per la source '$source_name'."
        rm -f -- "$merged_file" "$next_file"
        rmdir -- "$work_dir" 2>/dev/null || true
        return 1
      }

      for source_file in "${matches[@]}"; do
        [[ -f "$source_file" ]] || {
          loader_die "la source non è un file regolare: $source_file"
          rm -f -- "$merged_file" "$next_file"
          rmdir -- "$work_dir" 2>/dev/null || true
          return 1
        }

        if ! yq eval '.' "$source_file" >/dev/null; then
          loader_die "sintassi YAML non valida: $source_file"
          rm -f -- "$merged_file" "$next_file"
          rmdir -- "$work_dir" 2>/dev/null || true
          return 1
        fi

        if ! yq eval -e \
          'has(strenv(SOURCE_NAME))' "$source_file" >/dev/null; then
          loader_die "'$source_file' non contiene la chiave '$source_name'."
          rm -f -- "$merged_file" "$next_file"
          rmdir -- "$work_dir" 2>/dev/null || true
          return 1
        fi

        if ! yq eval -o=json \
          '{(strenv(SOURCE_NAME)): .[strenv(SOURCE_NAME)]}' \
          "$source_file" >"$fragment_file" ||
          ! yq eval-all -o=json \
            '. as $item ireduce ({}; . *+ $item)' \
            "$merged_file" "$fragment_file" >"$next_file"; then
          loader_die "impossibile caricare la source '$source_name'."
          rm -f -- "$merged_file" "$next_file" "$fragment_file"
          rmdir -- "$work_dir" 2>/dev/null || true
          return 1
        fi
        mv -- "$next_file" "$merged_file"
        loader_log "caricato: ${source_file#"$manifest_dir"/}"
      done
    done
  done

  cat -- "$merged_file"
  rm -f -- "$merged_file" "$next_file" "$fragment_file"
  rmdir -- "$work_dir" 2>/dev/null || true
  unset SOURCE_NAME
}

load_repoforge() {
  REPOFORGE_CONFIG_JSON="$(load_repoforge_config "${1:-repoforge.yaml}")" ||
    return 1
  export REPOFORGE_CONFIG_JSON
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  load_repoforge_config "${1:-repoforge.yaml}"
fi
