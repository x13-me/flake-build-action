#!/usr/bin/env bash

set -euo pipefail

export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf'
export GIT_CONFIG_VALUE_0='ssh://git@github.com/'
export GIT_CONFIG_KEY_1='http.https://github.com/.extraheader'
export GIT_CONFIG_VALUE_1="Authorization: Basic $(printf 'x-access-token:%s' "$PRIVATE_REPO_PAT" | base64 -w0)"

FLAKE_DIR="${1:-.}"
FLAKE_DIR="$(realpath "$FLAKE_DIR")"

SYSTEMS=("x86_64-linux" "aarch64-linux")

runner_for_system() {
  case "$1" in
    x86_64-linux)  echo "ubuntu-26.04" ;;
    aarch64-linux) echo "ubuntu-26.04-arm" ;;
    *) return 1 ;;
  esac
}

list_per_system() {
  local kind="$1" system="$2"
  nix eval --json \
    --no-write-lock-file \
    --accept-flake-config \
    "${FLAKE_DIR}#${kind}.${system}" \
    --apply 'builtins.attrNames' \
    2>/dev/null \
    | jq -r '.[]' \
    || true
}

has_formatter() {
  local system="$1"
  nix eval \
    --no-write-lock-file \
    --accept-flake-config \
    "${FLAKE_DIR}#formatter.${system}.drvPath" \
    >/dev/null 2>&1
}

arr_append() {
  printf '%s' "$1" | jq --arg n "$2" '. + [$n]'
}

declare -A pkg_arr=()
declare -A shell_arr=()
declare -A cfg_arr=()
declare -A fmt_flag=()

for system in "${SYSTEMS[@]}"; do
  pkg_arr["$system"]='[]'
  shell_arr["$system"]='[]'
  cfg_arr["$system"]='[]'
done

check_entries=()

for system in "${SYSTEMS[@]}"; do
  runner="$(runner_for_system "$system")"
  echo "--- ${system} (runner: ${runner}) ---" >&2

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "  pkg     ${name}" >&2
    pkg_arr["$system"]=$(arr_append "${pkg_arr["$system"]}" "$name")
  done < <(list_per_system packages "$system")

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "  shell   ${name}" >&2
    shell_arr["$system"]=$(arr_append "${shell_arr["$system"]}" "$name")
  done < <(list_per_system devShells "$system")

  if has_formatter "$system"; then
    echo "  fmt     formatter" >&2
    fmt_flag["$system"]=true
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "  check   ${name}  (own job)" >&2
    entry=$(jq -nc \
      --arg name   "check-${name} (${system})" \
      --arg system "$system" \
      --arg runner "$runner" \
      --arg cn     "$name" \
      '{name:$name, system:$system, runner:$runner, targets:[{checks:[$cn]}]}')
    check_entries+=("$entry")
  done < <(list_per_system checks "$system")
done

echo "--- nixosConfigurations ---" >&2

cfg_names_json=$(nix eval --json \
  --no-write-lock-file \
  --accept-flake-config \
  "${FLAKE_DIR}#nixosConfigurations" \
  --apply 'builtins.attrNames' \
  2>/dev/null || echo '[]')

mapfile -t cfg_names < <(printf '%s' "$cfg_names_json" | jq -r '.[]')

for name in "${cfg_names[@]}"; do
  [[ -z "$name" ]] && continue
  echo -n "  cfg     ${name} ... " >&2

  system=$(nix eval --raw \
    --no-write-lock-file \
    --accept-flake-config \
    "${FLAKE_DIR}#nixosConfigurations.${name}.config.nixpkgs.hostPlatform.system" \
    2>/dev/null) || {
    echo "WARN: eval failed, skipping" >&2
    continue
  }

  if ! runner_for_system "$system" >/dev/null; then
    echo "WARN: unsupported system '${system}', skipping" >&2
    continue
  fi

  echo "${system}" >&2
  cfg_arr["$system"]=$(arr_append "${cfg_arr["$system"]}" "$name")
done

include=()

for system in "${SYSTEMS[@]}"; do
  pkgs="${pkg_arr["$system"]}"
  shells="${shell_arr["$system"]}"
  cfgs="${cfg_arr["$system"]}"
  fmt="${fmt_flag["$system"]:-false}"

  total=$(jq -n \
    --argjson p "$pkgs" \
    --argjson s "$shells" \
    --argjson c "$cfgs" \
    --argjson f "$fmt" \
    '($p|length) + ($s|length) + ($c|length) + (if $f then 1 else 0 end)')
  [[ "$total" == "0" ]] && continue

  targets=$(jq -nc \
    --argjson p "$pkgs" \
    --argjson s "$shells" \
    --argjson c "$cfgs" \
    --argjson f "$fmt" \
    '[
      (if ($p | length) > 0 then {packages:            $p} else empty end),
      (if ($s | length) > 0 then {devShells:           $s} else empty end),
      (if $f             then {formatter:           true} else empty end),
      (if ($c | length) > 0 then {nixosConfigurations: $c} else empty end)
    ]')

  runner="$(runner_for_system "$system")"
  entry=$(jq -nc \
    --arg name    "$system" \
    --arg system  "$system" \
    --arg runner  "$runner" \
    --argjson targets "$targets" \
    '{name:$name, system:$system, runner:$runner, targets:$targets}')
  include+=("$entry")
done

for entry in "${check_entries[@]}"; do
  include+=("$entry")
done

if [[ ${#include[@]} -eq 0 ]]; then
  echo "No buildable targets found." >&2
  echo '{"include":[]}'
  exit 0
fi

batch_count=0
check_count=0
total_targets=0
for entry in "${include[@]}"; do
  is_check=$(printf '%s' "$entry" | jq -r '.targets[0] | has("checks")')
  n=$(printf '%s' "$entry" | jq '
    [ .targets[]
      | to_entries[]
      | (if (.value | type) == "array" then (.value | length) else 1 end)
    ] | add // 0')
  if [[ "$is_check" == "true" ]]; then
    (( check_count++ )) || true
  else
    (( batch_count++ )) || true
  fi
  total_targets=$(( total_targets + n ))
done

echo "--- ${total_targets} target(s): ${batch_count} batch job(s), ${check_count} check job(s) ---" >&2

printf '%s\n' "${include[@]}" | jq -sc '{include: .}'
