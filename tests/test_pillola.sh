#!/bin/zsh
# Prova end-to-end della dettatura nell'app accesa, senza incollare nulla:
# notetaker://detta, una frase detta dagli altoparlanti (say), notetaker://fine, poi il testo in stato-pillola.json.
# Poi una dettatura annullata non deve produrre testo. Serve il volume acceso e una stanza tranquilla.
set -euo pipefail
B="${0:A:h:h}"
STATO="$B/stato-pillola.json"
TMP=$(mktemp -d)
trap 'open -g "notetaker://senza-incolla?secondi=0"; rm -rf "$TMP"' EXIT

pgrep -x Notetaker >/dev/null || { echo "FALLITA: il Notetaker non è acceso"; exit 1; }
campo() { /usr/bin/python3 -c "import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print('' if v is None else v)" "$STATO" "$1"; }
attendi_stato() {  # attende che la pillola sia nello stato $1 (al massimo $2 secondi)
  for _ in $(seq 1 $(( $2 * 10 ))); do [[ "$(campo stato)" == "$1" ]] && return 0; sleep 0.1; done
  return 1
}

say -v Alice -o "$TMP/frase.aiff" "Bottega Quercia ha mandato il preventivo per le borse."
say -v Alice -o "$TMP/corta.aiff" "Questa frase non deve comparire."

open -g "notetaker://senza-incolla?secondi=120"
sleep 0.5
attendi_stato riposo 5 || { echo "FALLITA: la pillola non è a riposo ($(campo stato))"; exit 1; }
prima="$(campo ultimoIncollato)"

# 1. dettatura completa
open -g "notetaker://detta"
attendi_stato ascolto 5 || { echo "FALLITA: la pillola non è andata in ascolto ($(campo stato))"; exit 1; }
afplay "$TMP/frase.aiff"
sleep 0.5
open -g "notetaker://fine"
testo=""
for _ in $(seq 1 300); do
  testo="$(campo ultimoIncollato)"
  [[ "$testo" != "$prima" && -n "$testo" ]] && break
  sleep 0.1
done
if [[ "$testo" != *Bottega* && "$testo" != *Quercia* ]]; then
  echo "FALLITA: testo dettato non trovato (ultimoIncollato: '$testo')"; exit 1
fi
echo "dettato: $testo"
attendi_stato riposo 5 || { echo "FALLITA: dopo la dettatura la pillola non torna a riposo"; exit 1; }

# 2. dettatura annullata
open -g "notetaker://detta"
attendi_stato ascolto 5 || { echo "FALLITA: seconda dettatura non in ascolto"; exit 1; }
afplay "$TMP/corta.aiff"
open -g "notetaker://annulla"
sleep 5
[[ "$(campo ultimoIncollato)" == "$testo" ]] || { echo "FALLITA: la dettatura annullata ha prodotto testo"; exit 1; }
attendi_stato riposo 5 || { echo "FALLITA: dopo l'annullamento la pillola non torna a riposo"; exit 1; }

echo "OK"
