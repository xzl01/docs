#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DOC_PATH_RE='^(docs|i18n/en/docusaurus-plugin-content-docs/current)/.*\.(md|mdx)$'
PLACEHOLDER_RE='(^|[^A-Za-z0-9_])(TODO|TBD|XXX|XXXXXX)([^A-Za-z0-9_]|$)'

if [[ $# -eq 0 ]]; then
  echo "agent-doc-lint: no files provided, skipping."
  exit 0
fi

fail_count=0

err() {
  local msg="$1"
  echo "ERROR: ${msg}"
  fail_count=$((fail_count + 1))
}

is_partial_file() {
  local file="$1"
  local base
  base="$(basename "$file")"
  [[ "$base" =~ ^_ ]]
}

has_frontmatter() {
  local file="$1"
  local first_line
  first_line="$(head -n 1 "$file" || true)"
  [[ "$first_line" == "---" ]]
}

has_frontmatter_key() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" {in_fm=1; next}
    in_fm && $0 == "---" {exit}
    in_fm && $0 ~ ("^" key "[[:space:]]*:") {found=1; exit}
    END {exit(found ? 0 : 1)}
  ' "$file"
}

frontmatter_value() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" {in_fm=1; next}
    in_fm && $0 == "---" {exit}
    in_fm && $0 ~ ("^" key "[[:space:]]*:") {
      sub("^[^:]+:[[:space:]]*", "", $0)
      gsub(/^"|"$/, "", $0)
      gsub(/^'\''|'\''$/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

is_wrapper_file() {
  local file="$1"
  local import_count
  local total_lines
  local doc_kind
  doc_kind="$(frontmatter_value "$file" "doc_kind" || true)"
  if [[ "$doc_kind" == "wrapper" ]]; then
    return 0
  fi

  import_count="$(grep -Ec "^import[[:space:]]+.*[[:space:]]from[[:space:]]+['\\\"].*['\\\"];?$" "$file" || true)"
  total_lines="$(wc -l < "$file" | awk '{print $1}')"

  if [[ "$import_count" -ge 1 ]] && [[ "$total_lines" -le 40 ]]; then
    return 0
  fi

  return 1
}

frontmatter_list_values() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" {in_fm=1; next}
    in_fm && $0 == "---" {exit}
    in_fm {
      if (!in_list && $0 ~ ("^" key "[[:space:]]*:")) {
        in_list=1
        next
      }
      if (in_list) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
          val=$0
          sub(/^[[:space:]]*-[[:space:]]*/, "", val)
          gsub(/^"|"$/, "", val)
          gsub(/^'\''|'\''$/, "", val)
          print val
          next
        }
        if ($0 ~ /^[A-Za-z0-9_-]+[[:space:]]*:/) {
          exit
        }
      }
    }
  ' "$file"
}

check_unlabeled_fence() {
  local file="$1"
  awk '
    BEGIN {in_fence=0}
    /^[[:space:]]*```/ {
      line=$0
      gsub(/[[:space:]]+$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      if (in_fence == 0) {
        if (line == "```") {
          printf("%d\n", NR)
        }
        in_fence=1
      } else {
        in_fence=0
      }
    }
  ' "$file"
}

check_import_paths() {
  local file="$1"
  awk '
    /^[[:space:]]*import[[:space:]].*[[:space:]]from[[:space:]]+["\047][^"\047]+["\047];?[[:space:]]*$/ {
      line=$0
      match(line, /from[[:space:]]+["\047][^"\047]+["\047]/)
      if (RSTART > 0) {
        spec=substr(line, RSTART, RLENGTH)
        sub(/^from[[:space:]]+["\047]/, "", spec)
        sub(/["\047]$/, "", spec)
        printf("%d:%s\n", NR, spec)
      }
    }
  ' "$file"
}

check_raw_angle_placeholders() {
  local file="$1"
  awk '
    BEGIN {in_fence=0}
    /^[[:space:]]*```/ {
      in_fence = 1 - in_fence
      next
    }
    in_fence == 1 {next}
    {
      line=$0

      # If a line already uses inline code, skip strict placeholder scan
      # to avoid false positives on JSX/template-string rich lines.
      if (index(line, "`") > 0) {
        next
      }

      while (match(line, /<[a-z0-9]+-[a-z0-9-]+>(\.[A-Za-z0-9_.-]+)?/)) {
        token=substr(line, RSTART, RLENGTH)
        printf("%d:%s\n", NR, token)
        line=substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file"
}

for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    continue
  fi

  if [[ ! "$file" =~ $DOC_PATH_RE ]]; then
    continue
  fi

  if [[ "$(wc -c < "$file" | awk '{print $1}')" -eq 0 ]]; then
    err "$file is empty"
    continue
  fi

  if [[ "$file" != *"/template/"* ]]; then
    if grep -Enim 1 "$PLACEHOLDER_RE" "$file" >/dev/null; then
      hit="$(grep -Enim 1 "$PLACEHOLDER_RE" "$file" || true)"
      err "$file contains placeholder token: $hit"
    fi
  fi

  while IFS= read -r line_no; do
    [[ -z "$line_no" ]] && continue
    err "$file has unlabeled code fence at line $line_no"
  done < <(check_unlabeled_fence "$file")

  while IFS= read -r import_hit; do
    [[ -z "$import_hit" ]] && continue
    import_line="${import_hit%%:*}"
    import_path="${import_hit#*:}"

    if [[ "$import_path" == .* ]]; then
      import_target="$(dirname "$file")/$import_path"
      import_target_compat="${import_target//\\_/_}"

      if [[ ! -f "$import_target" && ! -f "$import_target_compat" ]]; then
        err "$file import target not found at line $import_line: $import_path"
      fi
    fi
  done < <(check_import_paths "$file")

  while IFS= read -r placeholder_hit; do
    [[ -z "$placeholder_hit" ]] && continue
    placeholder_line="${placeholder_hit%%:*}"
    placeholder_token="${placeholder_hit#*:}"
    err "$file has unescaped angle placeholder at line $placeholder_line: $placeholder_token (wrap in backticks)"
  done < <(check_raw_angle_placeholders "$file")

  if is_partial_file "$file"; then
    continue
  fi

  if is_wrapper_file "$file"; then
    if ! has_frontmatter "$file"; then
      err "$file wrapper missing front matter (must start with ---)"
      continue
    fi

    wrapper_kind="$(frontmatter_value "$file" "doc_kind" || true)"
    if [[ "$wrapper_kind" != "wrapper" ]]; then
      err "$file wrapper front matter missing doc_kind: wrapper"
    fi

    source_of_truth="$(frontmatter_value "$file" "source_of_truth" || true)"
    if [[ -z "$source_of_truth" ]]; then
      err "$file wrapper front matter missing source_of_truth"
    fi

    if ! has_frontmatter_key "$file" "imports_resolve_to"; then
      err "$file wrapper front matter missing imports_resolve_to"
      continue
    fi

    imports_count=0
    while IFS= read -r import_target; do
      [[ -z "$import_target" ]] && continue
      imports_count=$((imports_count + 1))
      if [[ ! -f "$import_target" ]]; then
        err "$file imports_resolve_to target not found: $import_target"
      fi
    done < <(frontmatter_list_values "$file" "imports_resolve_to")

    if [[ "$imports_count" -eq 0 ]]; then
      err "$file imports_resolve_to must contain at least one list item"
    fi

    continue
  fi

  if ! has_frontmatter "$file"; then
    err "$file missing front matter (must start with ---)"
    continue
  fi

  if ! grep -Eq '^sidebar_position[[:space:]]*:' "$file"; then
    err "$file front matter missing sidebar_position"
  fi

  first_heading="$(grep -En '^#{1,6} ' "$file" | head -n 1 || true)"
  if [[ -z "$first_heading" ]]; then
    err "$file missing heading"
    continue
  fi

  if [[ ! "$first_heading" =~ ^[0-9]+:\#\  ]]; then
    err "$file first heading is not H1: $first_heading"
  fi
done

if [[ "$fail_count" -gt 0 ]]; then
  echo "agent-doc-lint failed with ${fail_count} issue(s)."
  exit 1
fi

echo "agent-doc-lint passed."
