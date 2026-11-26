#!/bin/zsh
# Installa il Notetaker su questo Mac: ambiente Python, app in ~/Applications e manutenzione automatica.
# Uso: zsh installa.sh   (dalla cartella del repository, che va tenuta in ~/.config/trascrittore)
set -euo pipefail
B="${0:A:h}"
cd "$B"

echo "1/4 Ambiente Python (venv) con sherpa-onnx, numpy, soundfile, pytest"
[[ -x venv/bin/python ]] || uv venv --python 3.12 venv
VIRTUAL_ENV="$B/venv" uv pip install -q sherpa-onnx==2.0.3 numpy soundfile pytest

echo "   Registratore (ScreenCaptureKit): si compila solo se manca, per non perdere i permessi già dati"
[[ -x registra ]] || swiftc -O -target arm64-apple-macos15.0 -o registra registra.swift

echo "2/4 Cartella dei dati personali (fuori dal repository)"
mkdir -p dati
if [[ ! -f dati/profilo.json ]]; then
  cat >dati/profilo.json <<JSON
{
 "nome": "il tuo nome",
 "descrizione": "lavoro e città, per i prompt di Claude",
 "vault": "~/percorso/del/vault",
 "termini_fissi": []
}
JSON
  echo "   Scrivi i tuoi dati in $B/dati/profilo.json"
fi

echo "3/4 App Notetaker in ~/Applications"
zsh app/build.sh

echo "4/4 Manutenzione automatica (LaunchAgent, ogni 30 minuti)"
PLIST="$HOME/Library/LaunchAgents/it.notetaker.manutenzione.plist"
sed "s|__BASE__|$B|g" it.notetaker.manutenzione.plist >"$PLIST"
launchctl bootout "gui/$(id -u)/it.notetaker.manutenzione" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Fatto. Mancano i modelli (vedi README). Apri Notetaker da ~/Applications e dai i permessi (Accessibilità, Microfono, Registrazione schermo)."
