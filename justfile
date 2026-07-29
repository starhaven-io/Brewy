derived_data_path := env(
    "BREWY_DERIVED_DATA_PATH",
    "/private/tmp/brewy-deriveddata-" + sha256(justfile_directory())
)

# Build

# Build the app with xcodebuild
build:
    xcodebuild \
        -project Brewy.xcodeproj \
        -scheme Brewy \
        -destination 'generic/platform=macOS' \
        -configuration Debug \
        -derivedDataPath {{ quote(derived_data_path) }} \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        EXCLUDED_ARCHS=x86_64 \
        build

# Clean build artifacts
clean:
    xcodebuild clean \
        -project Brewy.xcodeproj \
        -scheme Brewy \
        -derivedDataPath {{ quote(derived_data_path) }}

# Setup

# fleet:block install-hooks
# Install git hooks (DCO sign-off + pre-push checks). Run once per clone.
install-hooks:
    git config core.hooksPath .githooks
# fleet:end

# Test

# Run unit tests (skips UI tests that require code signing locally)
test:
    xcodebuild test \
        -project Brewy.xcodeproj \
        -scheme Brewy \
        -destination 'platform=macOS' \
        -only-testing:BrewyTests \
        -enableCodeCoverage YES \
        -derivedDataPath {{ quote(derived_data_path) }} \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        EXCLUDED_ARCHS=x86_64

# Lint

# fleet:block audit
audit:
    zizmor --persona auditor .github/workflows/
# fleet:end

# Run SwiftLint
lint:
    swiftlint --strict

# Check for typos
typos:
    typos

# Scan for unused code (uses .periphery.yml)
periphery:
    periphery scan --clean-build

# Check README and CONTRIBUTING links
lychee:
    lychee --config lychee.toml README.md CONTRIBUTING.md

# Check

# Run all checks
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    skipped=()
    run() {
        echo "--- $1 ---"
        if ! "$@"; then
            failed=1
        fi
    }
    skip() {
        echo "--- $1 --- skipped ($2 not found)"
        skipped+=("$2 (brew install $3)")
    }
    if command -v swiftlint &>/dev/null; then
        run swiftlint --strict
    else
        skip lint swiftlint swiftlint
    fi
    if command -v typos &>/dev/null; then
        run typos
    else
        skip typos typos typos-cli
    fi
    if command -v zizmor &>/dev/null; then
        run zizmor --persona auditor .github/workflows/
    else
        skip audit zizmor zizmor
    fi
    if command -v periphery &>/dev/null; then
        # Match CI: tolerate periphery:ignore comments CI sees as redundant (SwiftUI $-binding refs).
        run periphery scan --strict --disable-update-check --no-superfluous-ignore-comments --clean-build \
            -- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO EXCLUDED_ARCHS=x86_64
    else
        skip periphery periphery periphery
    fi
    if command -v lychee &>/dev/null; then
        run lychee --config lychee.toml README.md CONTRIBUTING.md
    else
        skip lychee lychee lychee
    fi
    run xcodebuild test \
        -project Brewy.xcodeproj \
        -scheme Brewy \
        -destination 'platform=macOS' \
        -only-testing:BrewyTests \
        -enableCodeCoverage YES \
        -derivedDataPath {{ quote(derived_data_path) }} \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        EXCLUDED_ARCHS=x86_64
    if [ ${#skipped[@]} -gt 0 ]; then
        echo ""
        echo "Checks skipped due to missing tools:"
        for tool in "${skipped[@]}"; do
            echo "  - $tool"
        done
        failed=1
    fi
    exit $failed

# fleet:block pinprick-audit
pinprick-audit:
    pinprick audit .
# fleet:end
