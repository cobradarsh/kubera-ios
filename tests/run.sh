#!/bin/bash
# Logic tests on the build machine (macOS): the Foundation-only core of the app plus the Gmail reader's parsers.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-tests

echo "== core"
xcrun swiftc -O -parse-as-library -module-name KuberaCore App/Core/*.swift tests/CoreTests*.swift -o build-tests/coretests
build-tests/coretests App/Resources/merchants.json

if [ -f tests/MailTests.swift ]; then
    echo "== mail"
    xcrun swiftc -O -parse-as-library -module-name KuberaMail App/Mail/IMAPParser.swift App/Mail/MIMEDecoder.swift tests/MailTests.swift -o build-tests/mailtests
    build-tests/mailtests
fi
