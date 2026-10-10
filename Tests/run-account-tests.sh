#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
swiftc -parse-as-library Sources/MultimodelTracker/Models/Domain.swift Sources/MultimodelTracker/Models/BankedResetDetails.swift Sources/MultimodelTracker/Support/AntigravityServiceRoute.swift Tests/AccountReplacementTests.swift -o "$bin/account-tests"
"$bin/account-tests"
