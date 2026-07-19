#!/usr/bin/env bash
#
# publish-to-gh.sh — publish the current directory as a new GitHub repo.
# Inits git if needed, makes a first commit, creates the remote via `gh`, pushes.
#
# Usage:
#   publish-to-gh.sh [repo-name] [--public|--private] [--dry-run]
#
# Options:
#   repo-name     name for the new repo (default: current dir name)
#   --public      create a public repo         (default: --private)
#   --private     create a private repo
#   --dry-run     print the actions, change nothing
#
# Requires: git, gh (https://cli.github.com/), authenticated (`gh auth login`).

# Re-exec under bash when started as `sh publish-to-gh.sh` — bashisms below.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -euo pipefail

repo_name=""; visibility="--private"; dry=0
for a in "$@"; do
  case $a in
    --public)  visibility="--public" ;;
    --private) visibility="--private" ;;
    --dry-run) dry=1 ;;
    -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
    -*) echo "error: unknown option: $a" >&2; exit 2 ;;
    *)  repo_name=$a ;;
  esac
done
[[ -n $repo_name ]] || repo_name=$(basename "$PWD")

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

for cmd in git gh; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' not on PATH" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

if git remote get-url origin >/dev/null 2>&1; then
  echo "error: remote 'origin' already set: $(git remote get-url origin)" >&2
  exit 1
fi

[[ -d .git ]] || run git init -b main

if ! git config user.email >/dev/null; then
  read -rp "git user.name: "  name
  read -rp "git user.email: " email
  run git config user.name "$name"
  run git config user.email "$email"
fi

run git add -A
if git diff --cached --quiet 2>/dev/null; then
  echo "nothing staged — repo will be created empty."
else
  read -rp "Commit message [Initial commit]: " msg
  run git commit -q -m "${msg:-Initial commit}"
fi

echo "creating $visibility repo '$repo_name' and pushing…"
run gh repo create "$repo_name" "$visibility" --source=. --remote=origin --push
