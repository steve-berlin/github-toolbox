#!/usr/bin/env bash
#
# rewrite-contributors.sh — rewrite commit authorship so GitHub's Contributors
# graph reflects the real humans behind the repo. History is rewritten (every
# SHA changes). Nothing is pushed.
#
# Usage:
#   rewrite-contributors.sh [options]            # dry run
#   rewrite-contributors.sh --apply [options]
#
# Options (repeatable where noted):
#   --drop EMAIL              drop Co-authored-by: trailers for EMAIL (repeatable)
#                             default: noreply@anthropic.com
#   --map OLD=Name <new@x>    remap author+committer identity (repeatable)
#   --coauthor "Name <x>"     append a Co-authored-by: trailer to every commit
#   --apply                   actually rewrite; without it, dry run
#
# The --coauthor / --map emails must be verified emails on the GitHub account,
# otherwise the contributor graph will not link the commits to that user.

# Re-exec under bash when started as `sh rewrite-contributors.sh`. Must stay
# above `set -o pipefail` and the array assignments below — both are bashisms
# that dash dies on before any runtime check could report something useful.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -euo pipefail

DROP=() MAP=() COAUTHOR="" APPLY=0

while (( $# )); do
  case "$1" in
    --drop)     DROP+=("$2"); shift 2 ;;
    --map)      MAP+=("$2"); shift 2 ;;
    --coauthor) COAUTHOR="$2"; shift 2 ;;
    --apply)    APPLY=1; shift ;;
    -h|--help)  sed -n '3,20p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
(( ${#DROP[@]} )) || DROP=("noreply@anthropic.com")

cd "$(git rev-parse --show-toplevel)"
git rev-parse HEAD >/dev/null 2>&1 || { echo "error: repo has no commits." >&2; exit 1; }

branch="$(git symbolic-ref --short HEAD)"
commits="$(git rev-list --count HEAD)"
dirty="$(git status --porcelain)"

if [[ -n "$dirty" ]] && (( APPLY )); then
  echo "error: working tree is dirty; filter-branch refuses to run. Commit or stash first." >&2
  exit 1
fi

show() {
  echo "== $1 authors =="
  git log --branches --tags --format='%an <%ae>' | sort | uniq -c
  echo "== $1 co-author trailers =="
  git log --branches --tags --format='%B' | { grep -i '^Co-authored-by:' || echo "  (none)"; } | sort | uniq -c
  echo
}

echo "repo: $(pwd)   branch: ${branch}   commits: ${commits}"
[[ -n "$dirty" ]] && echo "warning: working tree dirty — --apply will refuse to run."
echo
show current

echo "== planned =="
for e in "${DROP[@]}";  do echo "  drop trailer:  <${e}>"; done
for p in "${MAP[@]}";   do echo "  rewrite:       ${p%%=*}  ->  ${p#*=}"; done
[[ -n "$COAUTHOR" ]] && echo "  add trailer:   ${COAUTHOR}"
echo

if (( ! APPLY )); then
  echo "dry run — nothing changed. Re-run with --apply to rewrite ${commits} commits."
  exit 0
fi

# filter-branch keeps its own refs/original/ backup, but -f on a later run wipes
# it; stamp an independent one. It must live outside refs/heads and refs/tags,
# or the rewrite below would rewrite the backup too and it would restore nothing.
backup="refs/backup/pre-rewrite-$(date +%Y%m%d-%H%M%S)"
git update-ref "$backup" HEAD
echo "backup ref: ${backup}"
echo

# --- message filter ---------------------------------------------------------
# Drop the unwanted trailers with a case-insensitive sed address; stripspace
# closes the blank line the deletion leaves behind; interpret-trailers places
# (and de-duplicates) the new one.
drop_re="$(IFS='|'; echo "${DROP[*]//./\\.}")"
msg_filter="sed -E '/^Co-authored-by:.*<(${drop_re})>/Id' | git stripspace"
[[ -n "$COAUTHOR" ]] && msg_filter+=" | git interpret-trailers --if-exists doNothing --trailer 'Co-authored-by: ${COAUTHOR}'"

# --- env filter -------------------------------------------------------------
# Sourced by /bin/sh (dash on Debian): POSIX only, no [[ ]].
env_filter=""
for p in "${MAP[@]}"; do
  old="${p%%=*}" new="${p#*=}"
  name="${new%% <*}" email="${new##*<}" && email="${email%>}"
  for role in AUTHOR COMMITTER; do
    env_filter+="if [ \"\$GIT_${role}_EMAIL\" = '${old}' ]; then"
    env_filter+=" export GIT_${role}_NAME='${name}' GIT_${role}_EMAIL='${email}'; fi; "
  done
done
[[ -n "$env_filter" ]] || env_filter=":"

FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --env-filter "$env_filter" \
  --msg-filter "$msg_filter" \
  --tag-name-filter cat -- --branches --tags

echo
show rewritten

cat <<EOF
Local rewrite done. Nothing has been pushed.

Review:   git log --format='%h %an <%ae>%n%b'
Restore:  git reset --hard ${backup}     # then: git update-ref -d ${backup}

Publishing needs a force push, which rewrites the remote branch and breaks every
existing clone and fork:
    git push --force-with-lease origin ${branch}

GitHub recomputes the Contributors graph asynchronously and only counts commits
on the default branch whose author email is attached to a GitHub account.
EOF
