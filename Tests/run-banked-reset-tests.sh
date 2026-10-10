#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
swiftc -parse-as-library Sources/MultimodelTracker/Models/Domain.swift Sources/MultimodelTracker/Models/BankedResetDetails.swift Tests/BankedResetTests.swift -o "$bin/banked-reset-tests"
"$bin/banked-reset-tests"
