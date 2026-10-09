#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
swiftc -parse-as-library Sources/MultimodelTracker/Models/Domain.swift Sources/MultimodelTracker/Models/GoogleQuotaSummary.swift Tests/GoogleQuotaSummaryTests.swift -o "$bin/google-quota-tests"
"$bin/google-quota-tests"
