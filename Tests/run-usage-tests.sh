#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
swiftc -parse-as-library Sources/MultimodelTracker/Models/UsageDetails.swift \
  Sources/MultimodelTracker/Support/ClaudeTelemetry.swift \
  Tests/MultimodelTrackerTests/TestSupport.swift Tests/MultimodelTrackerTests/UsageAttributionTests.swift \
  -o "$bin/usage-tests"
"$bin/usage-tests"
