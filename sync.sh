#!/usr/bin/env bash
# Plan or create selected skill links; never download, overwrite, or prune.
set -euo pipefail

usage() {
  while IFS= read -r line; do printf '%s\n' "$line"; done <<'EOF'
Usage: bash sync.sh [--apply] [--agent NAME ...]

Preview selected skill links by default; --apply creates them after preflight.
Repeat --agent to select multiple agents. Requires Bash 4.4+, jq, and GNU
coreutils. Git is needed only for selected vendor skills.
EOF
}

die() { printf 'sync: %s\n' "$*" >&2; exit 1; }
apply=false
declare -A selected=() vendor_urls=() vendor_revisions=() checked=() targets=()
declare -a actions=() destinations=() sources=()
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --apply) apply=true; shift ;;
    --agent)
      (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || die '--agent requires a name'
      selected["$2"]=1
      shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'Bash 4.4+ is required'

for utility in jq realpath dirname mkdir ln; do
  command -v "$utility" >/dev/null 2>&1 || die "Required command missing: $utility"
done
script=$(realpath -e -- "${BASH_SOURCE[0]}") || die 'Cannot locate sync.sh'
root=$(dirname -- "$script")
[[ -n "${HOME:-}" ]] || die 'HOME must be set'
home=$(realpath -e -- "$HOME") || die 'HOME must exist'
[[ -d "$home" && "$home" != / ]] || die 'HOME must be a directory other than /'

# Reject control characters before converting JSON fields into shell records.
manifest=$(jq -ce -s '
  def text: type == "string" and (explode | all(. >= 32 and . != 127));
  if length == 1 then .[0] else error("Expected one JSON document") end
  | if type == "object" and .version == 1 and (.agents | type == "object")
      and (.agents | to_entries | all(
        (.key | test("^[a-zA-Z0-9][a-zA-Z0-9._-]*$"))
        and (.value | type == "object")
        and (.value.skills | type == "array" and all(text))
        and ((.value.destination == null and (.value.skills | length == 0))
          or (.value.destination | text))))
    then . else error("Invalid manifest schema or unconfigured agent with skills") end
' "$root/manifest.json" 2>/dev/null) || die 'Invalid manifest.json (version, agents, destinations, or skills)'

locks=$(jq -ce -s '
  def text: type == "string" and length > 0 and (explode | all(. >= 32 and . != 127));
  if length == 1 then .[0] else error("Expected one JSON document") end
  | if type == "object" and .version == 1
      and (.repositories | type == "array") and (.imports | type == "array")
      and (.repositories | all(type == "object"
        and (.path | text) and (.repository | text)
        and (.revision | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))))
    then . else error("Invalid source schema") end
' "$root/sources.json" 2>/dev/null) || die 'Invalid sources.json (version, repositories, imports, or full commit SHA)'

valid_relative() {
  local value=$1 prefix=$2 component
  [[ "$value" == "$prefix/"* && "$value" != */ ]] || return 1
  local -a parts=()
  IFS=/ read -r -a parts <<< "$value"
  for component in "${parts[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
  done
}

while IFS=$'\t' read -r key url revision; do
  valid_relative "$key" vendor && [[ "${key#vendor/}" != */* ]] || die 'Vendor sources need vendor/<name> paths'
  [[ ! ${vendor_urls["$key"]+present} ]] || die "Duplicate vendor source: $key"
  vendor_urls["$key"]=$url
  vendor_revisions["$key"]=$revision
done < <(jq -r '.repositories[] | "\(.path)\t\(.repository)\t\(.revision)"' <<< "$locks")

for agent in "${!selected[@]}"; do
  jq -e --arg name "$agent" '.agents | has($name)' <<< "$manifest" >/dev/null || die "Unknown agent: $agent"
done

git_read() {
  local directory=$1
  shift
  # Do not print Git diagnostics or URLs that might include credentials.
  git -C "$directory" "$@" 2>/dev/null || die "Cannot inspect vendor repository: ${directory##*/}"
}

check_vendor() {
  local source=$1 relative key directory top head url state
  relative=${source#"$root/"}
  relative=${relative#vendor/}
  key=vendor/${relative%%/*}
  [[ ${vendor_urls["$key"]+present} ]] || die "No locked source record for $key"
  [[ ! ${checked["$key"]+present} ]] || return 0
  command -v git >/dev/null 2>&1 || die 'Required command missing: git (vendor skills)'
  directory=$root/$key
  top=$(git_read "$directory" rev-parse --show-toplevel)
  top=$(realpath -e -- "$top") || die "Cannot resolve vendor repository: $key"
  [[ "$top" == "$directory" ]] || die "$key must be an initialized separate Git repository"
  head=$(git_read "$directory" rev-parse HEAD)
  [[ "$head" == "${vendor_revisions["$key"]}" ]] || die "$key does not match its locked revision"
  url=$(git_read "$directory" config --get remote.origin.url)
  [[ "$url" == "${vendor_urls["$key"]}" ]] || die "$key origin does not match sources.json"
  state=$(git_read "$directory" status --porcelain --untracked-files=all)
  [[ -z "$state" ]] || die "$key has local changes; review before distributing skills"
  checked["$key"]=1
}

preflight() {
  local target=$1 source=$2 parent resolved
  parent=${target%/*}
  while [[ "$parent" != "$home" ]]; do
    [[ "$parent" == "$home/"* ]] || die 'Destination escaped HOME'
    [[ ! -L "$parent" && ( ! -e "$parent" || -d "$parent" ) ]] || die "Discovery parent must be a regular directory: $parent"
    parent=${parent%/*}
  done
  action=link
  if [[ -L "$target" ]]; then
    resolved=$(realpath -e -- "$target" 2>/dev/null) || die "Conflicting or broken symlink: $target"
    [[ "$resolved" == "$source" ]] || die "Conflicting symlink: $target"
    action=keep
  elif [[ -e "$target" ]]; then
    die "Refusing to overwrite existing entry: $target"
  fi
}

while IFS= read -r agent; do
  if ((${#selected[@]})) && [[ ! ${selected["$agent"]+present} ]]; then
    continue
  fi
  config=$(jq -c --arg name "$agent" '.agents[$name]' <<< "$manifest")
  if jq -e '.destination == null' <<< "$config" >/dev/null; then
    continue
  fi
  directory=$(jq -r '.destination' <<< "$config")
  valid_relative "$directory" '~' || die 'Agent destination must start with ~/ and stay inside home'
  directory=$home/${directory#\~/}
  while IFS= read -r value; do
    prefix=skills
    [[ "$value" != vendor/* ]] || prefix=vendor
    valid_relative "$value" "$prefix" || die "Invalid $prefix path: $value"
    [[ "$prefix" != skills || "${value#skills/}" != */* ]] || die 'Custom skills must use skills/<name> paths'
    source=$(realpath -e -- "$root/$value" 2>/dev/null) || die "Missing skill: $value"
    [[ "$source" == "$root/"* && -f "$source/SKILL.md" ]] || die "Missing or out-of-repository SKILL.md: $value"
    case "$source" in
      "$root/vendor/"*) check_vendor "$source" ;;
      "$root/skills/"*) [[ "$prefix" != vendor ]] || die "Vendor skill escaped its repository: $value" ;;
      *) die "Skill must reside inside skills/ or a locked vendor: $value" ;;
    esac
    skill_name=${value##*/}
    [[ "$skill_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Invalid skill directory name: $skill_name"
    if [[ "$agent" == claude-code && ( "$skill_name" == synced || "$skill_name" == anthropic-skills ) ]]; then
      die "Reserved Claude Code skill name: $skill_name"
    fi
    target=$directory/$skill_name
    [[ ! ${targets["$target"]+present} ]] || die "Duplicate skill destination: $target"
    targets["$target"]=1
    preflight "$target" "$source"
    actions+=("$action")
    destinations+=("$target")
    sources+=("$source")
  done < <(jq -r '.skills[]' <<< "$config")
done < <(jq -r '.agents | keys_unsorted[]' <<< "$manifest")

for target in "${destinations[@]}"; do
  parent=${target%/*}
  while [[ "$parent" != "$home" ]]; do
    [[ ! ${targets["$parent"]+present} ]] || die 'A selected skill overlaps another discovery directory'
    parent=${parent%/*}
  done
done

for index in "${!destinations[@]}"; do
  printf '%s: %s -> %s\n' "${actions[$index]}" "${destinations[$index]}" "${sources[$index]}"
done
if "$apply"; then
  for index in "${!destinations[@]}"; do
    target=${destinations[$index]}
    source=${sources[$index]}
    preflight "$target" "$source"
    if [[ "$action" == link ]]; then
      mkdir -p -- "${target%/*}" || die "Cannot create discovery directory: ${target%/*}"
      ln -sT -- "$source" "$target" || die "Cannot create skill link: $target"
    fi
  done
  printf 'Synced %s skill links.\n' "${#destinations[@]}"
else
  printf 'Planned %s skill links.\n' "${#destinations[@]}"
fi
