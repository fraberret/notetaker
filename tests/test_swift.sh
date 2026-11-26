#!/bin/zsh
# Compila ed esegue le prove Swift della pillola: logica pura, nessuna interfaccia.
set -euo pipefail
B="${0:A:h:h}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SORGENTI=("$B"/app/pillola/Logica.swift(N) "$B"/app/pillola/Impostazioni.swift(N) "$B"/tests/swift/*.swift)
swiftc -target arm64-apple-macos13.0 -o "$TMP/prove" "${SORGENTI[@]}"
"$TMP/prove"
