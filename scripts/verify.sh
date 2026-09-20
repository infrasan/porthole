#!/usr/bin/env bash
# Local/CI verification. Tests stop only children they create.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/verification
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors | tee build/verification/tests.log
.build/debug/Porthole --bench | tee build/verification/bench.log
.build/debug/Porthole --json > build/verification/scan.json
chmod 600 build/verification/scan.json
python3 -c 'import json; r=json.load(open("build/verification/scan.json")); assert r["version"] == 1 and not r.get("scanError")'
.build/debug/Porthole --snapshot build/verification/dark.png --demo --dark
.build/debug/Porthole --snapshot build/verification/light.png --demo
.build/debug/Porthole --snapshot build/verification/details.png --demo --dark --expand 4000
if .build/debug/Porthole --snapshot /dev/null/impossible.png --demo > build/verification/expected-error.log 2>&1; then
    echo "Snapshot unexpectedly succeeded with an invalid output path" >&2
    exit 1
fi
# A real live soak and manual keyboard/VoiceOver checks are separate release gates.
