#!/usr/bin/env bash
set -euo pipefail

# Keep CI's probe-build path filter in sync with inputs outside Brewy/Models or this directory.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

output_path="${1:?usage: build.sh OUTPUT_PATH}"

xcrun swiftc -o "${output_path}" \
  Brewy/Models/BrewJSONTypes.swift \
  Brewy/Models/PackageModel.swift \
  Brewy/Models/ExternalURLPolicy.swift \
  Brewy/Models/GitHubRepositoryURL.swift \
  scripts/brew-json-probe/main.swift
