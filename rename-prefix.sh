#!/usr/bin/env bash
# rename-prefix.sh — rename the generic Jira* class names (and the jirakit package)
# to the name of your real Jira project, e.g. "Csd" -> CsdField, CsdModel, csdkit/.
#
# Usage:
#   ./rename-prefix.sh <ProjectName> [path] [--dry-run]
#
# Examples:
#   ./rename-prefix.sh Csd                 # rename inside the current directory
#   ./rename-prefix.sh Csd ./src --dry-run # only list what would change
#
# Only identifiers are renamed. Prose such as "Jira API" or "Jira Service Management"
# and URLs are left alone. The script is idempotent: running it twice is harmless.

set -euo pipefail

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

DRY_RUN=0
ARGS=()
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help) usage 0 ;;
    *) ARGS+=("$a") ;;
  esac
done

[ "${#ARGS[@]}" -ge 1 ] || usage 1
PROJECT="${ARGS[0]}"
ROOT="${ARGS[1]:-.}"

if ! [[ "$PROJECT" =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
  echo "error: project name must start with an uppercase letter and contain only letters and digits (got '$PROJECT')" >&2
  exit 1
fi
if [ "$PROJECT" = "Jira" ]; then
  echo "Project name is already 'Jira'; nothing to do."
  exit 0
fi
[ -d "$ROOT" ] || { echo "error: '$ROOT' is not a directory" >&2; exit 1; }
command -v perl >/dev/null || { echo "error: perl is required" >&2; exit 1; }

LOWER="$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')"
export PROJECT LOWER

# Class-name suffixes that follow the Jira prefix. Longest first so JiraFieldId is not read as JiraField.
SUFFIXES='FieldId|FieldSpec|FieldMeta|Field|Model|IssueSchema|MetaProvider|Meta|Client|ApiError|Error|Kit'
export SUFFIXES

# Text files only; skip VCS, virtualenvs, caches, and this script itself.
mapfile -t FILES < <(
  find "$ROOT" \
    \( -name .git -o -name node_modules -o -name __pycache__ -o -name .venv -o -name venv \
       -o -name .mypy_cache -o -name .pytest_cache -o -name .ruff_cache \) -prune -o \
    -type f ! -name "$(basename "$0")" -print0 \
  | xargs -0 grep -IlE 'Jira(FieldId|FieldSpec|FieldMeta|Field|Model|IssueSchema|MetaProvider|Meta|Client|ApiError|Error|Kit)|jirakit' 2>/dev/null || true
)

# perl: replace the identifier forms only.
PERL_EXPR='
  s/(?<![A-Za-z0-9_])((?:Http)?)Jira(?=(?:$ENV{SUFFIXES})(?![A-Za-z0-9_]))/$1$ENV{PROJECT}/g;
  s/(?<![A-Za-z0-9_])jirakit(?![A-Za-z0-9_])/$ENV{LOWER}kit/g;
'

changed=0
for f in "${FILES[@]}"; do
  [ -n "$f" ] || continue
  count="$(perl -ne '
    $n += () = /(?<![A-Za-z0-9_])(?:Http)?Jira(?=(?:$ENV{SUFFIXES})(?![A-Za-z0-9_]))|(?<![A-Za-z0-9_])jirakit(?![A-Za-z0-9_])/g;
    END { print $n + 0 }' "$f")"
  [ "$count" -gt 0 ] || continue
  changed=$((changed + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would change $f ($count occurrences)"
  else
    perl -pi -e "$PERL_EXPR" "$f"
    echo "changed $f ($count occurrences)"
  fi
done

# Rename directories called jirakit (deepest first).
while IFS= read -r d; do
  [ -n "$d" ] || continue
  target="$(dirname "$d")/${LOWER}kit"
  if [ -e "$target" ]; then
    echo "skip: $target already exists, leaving $d in place" >&2
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would rename $d -> $target"
  else
    mv "$d" "$target"
    echo "renamed $d -> $target"
  fi
done < <(find "$ROOT" -depth -type d -name jirakit ! -path '*/.git/*' 2>/dev/null)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: $changed file(s) would change. Re-run without --dry-run to apply."
else
  echo "done: $changed file(s) changed. Review with 'git diff' and run your tests."
fi
