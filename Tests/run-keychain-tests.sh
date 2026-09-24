#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
swiftc -parse-as-library Sources/MultimodelTracker/Support/CredentialReadGate.swift \
  Tests/CredentialReadGateTests.swift -o "$bin/keychain-tests"
"$bin/keychain-tests"
