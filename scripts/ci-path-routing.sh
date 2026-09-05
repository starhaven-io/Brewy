#!/usr/bin/env bash

reset_ci_routes() {
  NEEDS_LINT=0
  NEEDS_TESTS=0
  NEEDS_PROBE=0
  NEEDS_RELEASE_HELPERS=0
  RUN_CODEQL=false
  RUN_ZIZMOR=false
}

select_all_ci_routes() {
  NEEDS_LINT=1
  NEEDS_TESTS=1
  NEEDS_PROBE=1
  NEEDS_RELEASE_HELPERS=1
  RUN_CODEQL=true
  RUN_ZIZMOR=true
}

route_ci_path() {
  local path="$1"
  local routed=0

  if [[ "${path}" == *.swift || "${path}" == Brewy/* || "${path}" == BrewyTests/* ||
        "${path}" == BrewyUITests/* || "${path}" == Brewy.xcodeproj/* ||
        "${path}" == .swiftlint.yml || "${path}" == .github/workflows/ci.yml ]]; then
    NEEDS_LINT=1
    NEEDS_TESTS=1
    routed=1
  fi

  if [[ "${path}" == *.md || "${path}" == _typos.toml ]]; then
    NEEDS_LINT=1
    routed=1
  fi

  if [[ "${path}" == .github/workflows/release.yml ||
        "${path}" == .github/format-release-notes.py ||
        "${path}" == .github/appcast-template.xml ||
        "${path}" == scripts/validate-release-helpers.py ]]; then
    NEEDS_LINT=1
    NEEDS_RELEASE_HELPERS=1
    routed=1
  fi

  if [[ "${path}" == Brewy/Models/* || "${path}" == scripts/brew-json-probe/* ||
        "${path}" == .github/workflows/brew-json-probe.yml ||
        "${path}" == .github/workflows/ci.yml ]]; then
    NEEDS_PROBE=1
    routed=1
  fi

  if [[ "${path}" == Brewy/* || "${path}" == BrewyTests/* || "${path}" == BrewyUITests/* ]]; then
    RUN_CODEQL=true
    routed=1
  fi

  if [[ "${path}" == .github/workflows/* ]]; then
    RUN_ZIZMOR=true
    routed=1
  fi

  if [[ "${path}" == assets/* || "${path}" == .github/* || "${path}" == scripts/* ||
        "${path}" == .githooks/* || "${path}" == .* || "${path}" == LICENSE ||
        "${path}" == justfile ]]; then
    NEEDS_LINT=1
    routed=1
  fi

  if [[ "${routed}" -eq 0 ]]; then
    select_all_ci_routes
  fi
}

assert_source_path_routes() {
  reset_ci_routes
  route_ci_path "$1"
  [[ "${NEEDS_LINT}" -eq 1 ]]
  [[ "${NEEDS_TESTS}" -eq 1 ]]
  [[ "${RUN_CODEQL}" == true ]]
}

validate_ci_path_routing() {
  local source_paths=(
    $'Brewy/quoted\tinput.swift'
    $'Brewy/newline\ninput.swift'
    'Brewy/double"quote.swift'
    'Brewy/back\slash.swift'
    'Brewy/non-ASCII-café.swift'
    'Brewy/space name.swift'
    'Brewy/Info.plist'
    'Brewy/Brewy.entitlements'
    'Brewy/AppIcon.icon/icon.json'
    'Brewy/AppIcon.icon/Assets/box.svg'
    'BrewyTests/Fixtures/appcast.xml'
    'BrewyUITests/Fixtures/screenshot.png'
  )
  local path
  for path in "${source_paths[@]}"; do
    assert_source_path_routes "${path}"
  done

  reset_ci_routes
  route_ci_path '-leading-dash'
  [[ "${NEEDS_LINT}" -eq 1 ]]
  [[ "${NEEDS_TESTS}" -eq 1 ]]
  [[ "${NEEDS_PROBE}" -eq 1 ]]
  [[ "${NEEDS_RELEASE_HELPERS}" -eq 1 ]]
  [[ "${RUN_CODEQL}" == true ]]
  [[ "${RUN_ZIZMOR}" == true ]]

  reset_ci_routes
  route_ci_path 'README.md'
  [[ "${NEEDS_LINT}" -eq 1 ]]
  [[ "${NEEDS_TESTS}" -eq 0 ]]
  [[ "${RUN_CODEQL}" == false ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  if [[ "${1:-}" != "--self-test" ]]; then
    echo "usage: $0 --self-test" >&2
    exit 2
  fi
  validate_ci_path_routing
  echo "CI path routing validation passed."
fi
