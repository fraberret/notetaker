#!/bin/zsh
# Prova vera del microfono della dettatura (serve il permesso del Microfono al Terminale):
# la cattura deve ricevere il primo audio entro 4 secondi, con "Microfono del Mac" e con "Automatico".
# Il 27/11/2026 la dettatura non partiva più ("configuration changed" all'avvio): questa prova lo trova.
set -euo pipefail
B="${0:A:h:h}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -target arm64-apple-macos13.0 -o "$T/prova" "$B/app/pillola/Cattura.swift" "$B/app/pillola/Logica.swift" \
  "$B/tests/cattura/main.swift" -framework AVFoundation -framework CoreAudio -framework AppKit
errori=0
for m in - auto; do
  r=$("$T/prova" "$m" 2>&1 || true)
  if print -r -- "$r" | grep -q "primo true errore false"; then echo "OK   microfono '$m'"; else echo "FAIL microfono '$m': $r"; errori=$((errori+1)); fi
done
exit $errori
