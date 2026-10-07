#!/usr/bin/env bash
# Isolated filesystem/Git fixtures only: no real home, network, or skill execution.
set -euo pipefail
test_script=$(realpath -e -- "${BASH_SOURCE[0]}")
project_root=$(dirname -- "$(dirname -- "$test_script")")
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

fixture() {
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/agents-shell-test.XXXXXX")
  trap 'rm -rf -- "$scratch"' EXIT
  fixture_root=$scratch/agents
  fixture_home=$scratch/home
  fixture_path=$PATH
  mkdir -p -- "$fixture_root" "$fixture_home"
  cp -- "$project_root/sync.sh" "$project_root/Makefile" "$fixture_root/"
  cat > "$fixture_root/manifest.json" <<'EOF'
{"version":1,"agents":{
  "codex":{"destination":"~/.agents/skills","skills":["skills/review"]},
  "claude-code":{"destination":"~/.claude/skills","skills":["skills/review"]},
  "pi":{"destination":null,"skills":[]}
}}
EOF
  printf '%s\n' '{"version":1,"repositories":[],"imports":[]}' > "$fixture_root/sources.json"
  skill skills/review
}
skill() {
  mkdir -p -- "$fixture_root/$1"
  printf '%s\n' '---' 'name: review' 'description: Mock review skill' '---' > "$fixture_root/$1/SKILL.md"
}
manifest() {
  jq "$@" "$fixture_root/manifest.json" > "$scratch/manifest.next"
  mv -- "$scratch/manifest.next" "$fixture_root/manifest.json"
}
locks() {
  jq "$@" "$fixture_root/sources.json" > "$scratch/sources.next"
  mv -- "$scratch/sources.next" "$fixture_root/sources.json"
}
run_sync() {
  env HOME="$fixture_home" PATH="$fixture_path" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$fixture_root/sync.sh" "$@" > "$scratch/stdout" 2> "$scratch/stderr"
}
success() {
  if ! run_sync "$@"; then cat -- "$scratch/stderr" >&2; fail 'Expected sync success'; fi
}
refuse() { if run_sync "$@"; then fail 'Expected sync refusal'; fi; }
empty_directory() {
  local -a entries=()
  shopt -s nullglob dotglob
  entries=("$1"/*)
  ((${#entries[@]} == 0)) || fail "Directory was changed: $1"
}
no_entry() { [[ ! -e "$1" && ! -L "$1" ]] || fail "Unexpected entry: $1"; }
link_to() { [[ -L "$1" && "$(realpath -e -- "$1")" == "$2" ]] || fail "Wrong link: $1"; }

plan_and_repeat() {
  success
  empty_directory "$fixture_home"
  success --apply
  link_to "$fixture_home/.agents/skills/review" "$fixture_root/skills/review"
  link_to "$fixture_home/.claude/skills/review" "$fixture_root/skills/review"
  success --apply
  [[ $(grep -c '^keep:' "$scratch/stdout") == 2 ]] || fail 'Repeat sync did not retain both links'
}
all_targets_preflight() {
  mkdir -p -- "$fixture_home/.claude/skills/review"
  refuse --apply
  no_entry "$fixture_home/.agents"
  [[ -d "$fixture_home/.claude/skills/review" ]] || fail 'Existing directory replaced'
}
broken_link() {
  mkdir -p -- "$fixture_home/.agents/skills"
  ln -s -- "$fixture_home/missing" "$fixture_home/.agents/skills/review"
  refuse --apply
  [[ $(readlink -- "$fixture_home/.agents/skills/review") == "$fixture_home/missing" ]] || fail 'Broken link replaced'
}
existing_file_and_reserved_name() {
  mkdir -p -- "$fixture_home/.agents/skills"
  printf 'preserve' > "$fixture_home/.agents/skills/review"
  refuse --apply
  [[ $(cat "$fixture_home/.agents/skills/review") == preserve ]] || fail 'Existing file overwritten'
  skill skills/synced
  manifest '.agents["claude-code"].skills = ["skills/synced"]'
  refuse --apply --agent claude-code
  no_entry "$fixture_home/.claude"
}
source_escape() {
  mkdir -p -- "$scratch/outside"
  printf 'mock\n' > "$scratch/outside/SKILL.md"
  ln -s -- "$scratch/outside" "$fixture_root/skills/escape"
  manifest '.agents.codex.skills = ["skills/escape"]'
  refuse --apply
  empty_directory "$fixture_home"
}
discovery_parent_link() {
  mkdir -p -- "$scratch/elsewhere"
  ln -s -- "$scratch/elsewhere" "$fixture_home/.agents"
  refuse --apply
  empty_directory "$scratch/elsewhere"
}
unselected_skills_retained() {
  mkdir -p -- "$fixture_home/.agents/skills"
  printf 'preserve' > "$fixture_home/.agents/skills/other"
  success --apply --agent codex
  [[ $(cat "$fixture_home/.agents/skills/other") == preserve ]] || fail 'Unmanaged skill changed'
  no_entry "$fixture_home/.claude"
  manifest '.agents.codex.skills = []'
  success --apply --agent codex
  link_to "$fixture_home/.agents/skills/review" "$fixture_root/skills/review"
}
invalid_selections() {
  cp -- "$fixture_root/manifest.json" "$scratch/original.json"
  local filter
  for filter in \
    '.agents.codex.skills = ["../outside"]' \
    '.agents.codex.skills = ["skills/missing"]' \
    '.agents.codex.skills = ["skills/review", "skills/review"]' \
    '.agents.codex.destination = "~/../outside"' \
    '.agents.codex.destination = "/tmp/unsafe"' \
    '.agents.pi.skills = ["skills/review"]'; do
    cp -- "$scratch/original.json" "$fixture_root/manifest.json"
    manifest "$filter"
    refuse --apply
    empty_directory "$fixture_home"
  done
  cp -- "$scratch/original.json" "$fixture_root/manifest.json"
  refuse --agent unknown
  refuse --agent
  refuse --unknown
}
no_python_on_path() {
  local utility target
  mkdir -p -- "$scratch/bin"
  for utility in bash jq realpath dirname mkdir ln make; do
    ln -s -- "$(command -v "$utility")" "$scratch/bin/$utility"
  done
  fixture_path=$scratch/bin
  [[ ! -e "$fixture_path/python3" && ! -e "$fixture_path/python" ]] || fail 'Python present in runtime PATH'
  success
  for target in plan sync; do
    (cd "$fixture_root"; env HOME="$fixture_home" PATH="$fixture_path" make "$target") > "$scratch/make-output" 2>&1 || {
      cat -- "$scratch/make-output" >&2
      fail "Make $target failed without Python"
    }
  done
  link_to "$fixture_home/.agents/skills/review" "$fixture_root/skills/review"
}
missing_jq_and_help() {
  mkdir -p -- "$scratch/bin"
  ln -s -- "$(command -v bash)" "$scratch/bin/bash"
  fixture_path=$scratch/bin
  success --help
  refuse --apply
  grep -q 'Required command missing: jq' "$scratch/stderr" || fail 'Missing jq diagnostic'
  empty_directory "$fixture_home"
}
empty_manifest() {
  manifest '.agents |= with_entries(.value.skills = [])'
  success --apply
  empty_directory "$fixture_home"
}
spaces_and_backslashes() {
  fixture_home=$scratch/'home with spaces'
  mkdir -p -- "$fixture_home"
  manifest '.agents.codex.destination = "~/.agents\\custom/skills"'
  success --apply
  link_to "$fixture_home/.agents\\custom/skills/review" "$fixture_root/skills/review"
}
controls_and_overlap() {
  manifest '.agents.codex.destination = "~/.agents\n/skills"'
  refuse --apply
  empty_directory "$fixture_home"
  manifest '.agents.codex.destination = "~/.agents/skills" | .agents["claude-code"].destination = "~/.agents/skills/review/nested"'
  refuse --apply
  empty_directory "$fixture_home"
}
vendor_git() {
  env HOME="$fixture_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$fixture_root/vendor/example" "$@"
}
vendor_locks() {
  skill vendor/example/skills/review
  vendor_git init -b main > "$scratch/git-output" 2>&1
  vendor_git remote add origin https://github.com/example/skills.git
  vendor_git add .
  vendor_git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    commit -m 'Mock skill' > "$scratch/git-output" 2>&1
  local revision
  revision=$(vendor_git rev-parse HEAD)
  locks --arg revision "$revision" '.repositories = [{path:"vendor/example", repository:"https://github.com/example/skills.git", revision:$revision}]'
  manifest '.agents.codex.skills = ["vendor/example/skills/review"]'
  success
  locks '.repositories[0].revision = "0000000000000000000000000000000000000000"'
  refuse --apply
  locks --arg revision "$revision" '.repositories[0].revision = $revision | .repositories[0].repository = "https://github.com/other/skills.git"'
  refuse --apply
  locks '.repositories[0].repository = "https://github.com/example/skills.git"'
  printf 'changed\n' > "$fixture_root/vendor/example/skills/review/SKILL.md"
  refuse --apply
  empty_directory "$fixture_home"
}
malformed_json() {
  printf 'not JSON\n' > "$fixture_root/manifest.json"
  refuse --apply
  empty_directory "$fixture_home"
}

tests=(plan_and_repeat all_targets_preflight broken_link existing_file_and_reserved_name
  source_escape discovery_parent_link unselected_skills_retained invalid_selections
  no_python_on_path missing_jq_and_help empty_manifest spaces_and_backslashes
  controls_and_overlap vendor_locks malformed_json)
if [[ "${1:-}" == --case ]]; then
  [[ $# == 2 ]] || fail 'Expected one test case'
  for test in "${tests[@]}"; do
    if [[ "$test" == "$2" ]]; then fixture; "$test"; exit 0; fi
  done
  fail "Unknown test case: $2"
fi
passed=0
failed=0
for test in "${tests[@]}"; do
  # A fresh Bash process preserves errexit within each case and isolates state.
  if bash "$test_script" --case "$test"; then
    printf 'ok - %s\n' "$test"
    passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$test" >&2
    failed=$((failed + 1))
  fi
done
printf '%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
