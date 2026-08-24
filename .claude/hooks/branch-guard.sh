#!/usr/bin/env bash
# PreToolUse/Bash guard for kovostack-helm-charts.
#
# Pushes to this repository may only land on upgrade/** branches. Everything
# else — main, a tag, --tags, --all, --mirror — is denied. The guard resolves
# the push's remote first and exits silently for any other repository, so it is
# safe to install globally.
set -uo pipefail

GUARDED_REPO_RE='kovostack-helm-charts(\.git)?$'
ALLOWED_PREFIX='upgrade/'

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

check_dest() {
  local dest=$1 what=$2
  case $dest in
    "")   deny "Push blocked: could not work out which branch this push lands on (detached HEAD?). Push explicitly: git push -u origin upgrade/<slug>" ;;
    refs/tags/*) deny "Push blocked: kovostack-helm-charts tags are cut by a human on main after the PR merges, never by the agent. Push the upgrade/** branch and let the release step tag it." ;;
    "$ALLOWED_PREFIX"*) return 0 ;;
    *)    deny "Push blocked: kovostack-helm-charts only accepts pushes to ${ALLOWED_PREFIX}** branches, and this push targets '${dest}' (from '${what}'). Move the work onto an upgrade/<slug> branch, push that, and open a PR against main." ;;
  esac
}

check_segment() {
  local seg=$1
  local -a t
  read -ra t <<<"$seg" || return 0
  (( ${#t[@]} >= 2 )) || return 0
  case ${t[0]} in git|*/git) ;; *) return 0 ;; esac

  # Walk the pre-subcommand options to find `push` and any `-C <dir>`.
  local i=1 dir=$PWD sub=""
  while (( i < ${#t[@]} )); do
    case ${t[i]} in
      -C)          dir=${t[i+1]:-$PWD}; (( i += 2 )) ;;
      -c|--namespace) (( i += 2 )) ;;
      -*)          (( i++ )) ;;
      *)           sub=${t[i]}; (( i++ )); break ;;
    esac
  done
  [[ $sub == push ]] || return 0

  local -a refspecs=()
  local remote="" blocked_flag="" a
  while (( i < ${#t[@]} )); do
    a=${t[i]}
    case $a in
      --tags|--all|--mirror|--follow-tags) blocked_flag=$a ;;
      --repo)                remote=${t[i+1]:-}; (( i++ )) ;;
      --repo=*)              remote=${a#--repo=} ;;
      -o|--push-option|--receive-pack|--exec) (( i++ )) ;;
      -*)                    ;;
      *) if [[ -z $remote ]]; then remote=$a; else refspecs+=("$a"); fi ;;
    esac
    (( i++ ))
  done

  # Only guard this one repository — resolve the remote name to its URL.
  local url
  remote=${remote:-origin}
  url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || url=$remote
  [[ $url =~ $GUARDED_REPO_RE ]] || return 0

  [[ -n $blocked_flag ]] && deny "Push blocked: '${blocked_flag}' pushes refs in bulk and can reach main or a release tag in kovostack-helm-charts. Push one upgrade/** branch by name instead."

  local rs dest branch
  if (( ${#refspecs[@]} == 0 )); then
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    check_dest "$branch" "current branch"
    return 0
  fi

  for rs in "${refspecs[@]}"; do
    dest=${rs##*:}
    dest=${dest#+}
    dest=${dest#refs/heads/}
    if [[ $dest == HEAD ]]; then
      dest=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || dest=""
    fi
    check_dest "$dest" "$rs"
  done
}

payload=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || exit 0
[[ -n $cmd ]] || exit 0
[[ $cmd == *push* ]] || exit 0

while IFS= read -r segment; do
  segment=${segment#"${segment%%[![:space:]]*}"}
  [[ -n $segment ]] || continue
  check_segment "$segment"
done < <(printf '%s\n' "$cmd" | sed -E 's/&&|\|\||;|\|/\n/g')

exit 0
