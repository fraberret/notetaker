#!/bin/zsh
# Prove della pipeline delle call, tutto in cartelle temporanee (mai nel vault reale).
set -u
B="${0:A:h:h}"
T=$(mktemp -d)
export CALL_DESTINAZIONE="$T/vault/90 Fonti/Trascrizioni" CALL_NOTE_DESTINAZIONE="$T/vault/00 Inbox"
export CALL_DATI="$T/dati" CALL_REGISTRAZIONI="$T/reg" CALL_STATO="$T/stato" CALL_NOTIFICHE=0
mkdir -p "$CALL_DESTINAZIONE" "$CALL_NOTE_DESTINAZIONE" "$CALL_REGISTRAZIONI" "$CALL_DATI"
errori=0
ok() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; errori=$((errori+1)); fi }
conta() { print -l -- $~1(N) | grep -c . }

registrazione_finta() {  # $1 = nome cartella
  local d="$CALL_REGISTRAZIONI/$1"; mkdir -p "$d"
  print -r -- '{"inizio_sistema": 100.0, "inizio_microfono": 100.0}' >"$d/inizio.json"
  print -r -- '{"transcription":[{"offsets":{"from":1000,"to":3000},"text":" ciao come stai"}]}' >"$d/microfono.json"
  print -r -- '{"transcription":[{"offsets":{"from":5000,"to":8000},"text":" bene grazie lavoro per Querchia"}]}' >"$d/sistema.json"
  print -r -- "$d"
}

# --- Caso A: Claude risponde (finto, eco) ---
A=$(registrazione_finta 2026-11-20_10-00-00)
CALL_CLAUDE="$B/tests/finto_claude.sh" "$B/call" trascrivi "$A" "Dell'Orto" >/dev/null
ok "A: un solo .txt nel vault" '[[ $(conta "$CALL_DESTINAZIONE/*.txt") == 1 ]]'
ok "A: nome con apostrofo" '[[ -f "$CALL_DESTINAZIONE/2026-11-20 Trascrizione call Dell'"'"'Orto.txt" ]]'
ok "A: una sola nota" '[[ $(conta "$CALL_NOTE_DESTINAZIONE/*.md") == 1 ]]'
ok "A: nessun in-attesa" '[[ ! -e "$A/in-attesa" ]]'
ok "A: grezza presente" '[[ -s "$A/trascrizione-grezza.txt" ]]'
rm -f "$CALL_DESTINAZIONE"/* "$CALL_NOTE_DESTINAZIONE"/*

# --- Caso B: Claude non raggiungibile ---
Bd=$(registrazione_finta 2026-11-21_10-00-00)
CALL_CLAUDE=/usr/bin/false "$B/call" trascrivi "$Bd" "Società Ìtalia" >/dev/null
ok "B: niente nel vault" '[[ $(conta "$CALL_DESTINAZIONE/*") == 0 && $(conta "$CALL_NOTE_DESTINAZIONE/*") == 0 ]]'
ok "B: in-attesa presente" '[[ -e "$Bd/in-attesa" ]]'
CALL_CLAUDE=/usr/bin/false "$B/call" riprova >/dev/null
ok "B: riprova prima delle 24 ore non completa" '[[ -e "$Bd/in-attesa" && $(conta "$CALL_DESTINAZIONE/*") == 0 ]]'
touch -t "$(date -v-25H +%Y%m%d%H%M)" "$Bd/in-attesa"
CALL_CLAUDE="$B/tests/finto_claude_rotto.sh" "$B/call" riprova >/dev/null
ok "B: dopo 24 ore il .txt nel vault" '[[ $(conta "$CALL_DESTINAZIONE/*.txt") == 1 ]]'
ok "B: da-rileggere presente" '[[ -e "$Bd/da-rileggere" && ! -e "$Bd/in-attesa" ]]'
ok "B: una sola nota" '[[ $(conta "$CALL_NOTE_DESTINAZIONE/*.md") == 1 ]]'
ok "B: segnata da rileggere nei dati" 'grep -q "Società Ìtalia" "$CALL_DATI/da-rileggere.json"'
CALL_CLAUDE="$B/tests/finto_claude_rotto.sh" "$B/call" riprova >/dev/null
ok "B: riprova non duplica" '[[ $(conta "$CALL_DESTINAZIONE/*.txt") == 1 && $(conta "$CALL_NOTE_DESTINAZIONE/*.md") == 1 ]]'

# --- Caso C: pulizia degli audio ---
vecchio="$CALL_DESTINAZIONE/2026-08-01 Trascrizione call Vecchia.m4a"
recente="$CALL_DESTINAZIONE/2026-11-16 Trascrizione call Recente.m4a"
altro="$CALL_DESTINAZIONE/2026-08-01 Audio Incontro - Alice.m4a"
senza_txt="$CALL_DESTINAZIONE/2026-08-02 Trascrizione call Orfana.m4a"
: >"$vecchio"; : >"$recente"; : >"$altro"; : >"$senza_txt"
: >"${vecchio%.m4a}.txt"; : >"${recente%.m4a}.txt"
for f in "$vecchio" "$altro" "$senza_txt"; do touch -t "$(date -v-91d +%Y%m%d%H%M)" "$f"; done
touch -t "$(date -v-10d +%Y%m%d%H%M)" "$recente"
print -r -- '{"giorni_audio": 0}' >"$CALL_DATI/impostazioni.json"
"$B/call" pulisci >/dev/null
ok "C: giorni_audio 0 non cancella" '[[ -e "$vecchio" && -e "$recente" ]]'
rm "$CALL_DATI/impostazioni.json"
"$B/call" pulisci >/dev/null
ok "C: 91 giorni cancellato" '[[ ! -e "$vecchio" ]]'
ok "C: 10 giorni resta" '[[ -e "$recente" ]]'
ok "C: audio non di una call resta" '[[ -e "$altro" ]]'
ok "C: audio senza trascrizione accanto resta" '[[ -e "$senza_txt" ]]'
ok "C: annotato" 'grep -q "Vecchia" "$CALL_DATI/audio-cancellati.json"'
ok "C: i .txt restano" '[[ $(conta "$CALL_DESTINAZIONE/*.txt") == 3 ]]'

# --- Caso D: manca il microfono (call del 27/11/2026): l'audio della call si salva lo stesso ---
D="$CALL_REGISTRAZIONI/2026-11-22_10-00-00"; mkdir -p "$D"
print -r -- '{"inizio_sistema": 100.0, "inizio_microfono": null}' >"$D/inizio.json"
ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:duration=2" -ar 48000 -ac 1 -c:a pcm_f32le "$D/sistema.caf"
CALL_WHISPER="$B/tests/finto_whisper.sh" CALL_CLAUDE="$B/tests/finto_claude.sh" "$B/call" trascrivi "$D" "Senza Microfono" >/dev/null
ok "D: audio nel vault anche senza microfono" '[[ -s "$CALL_DESTINAZIONE/2026-11-22 Trascrizione call Senza Microfono.m4a" ]]'
ok "D: grezzi tolti dopo il salvataggio" '[[ $(conta "$D/*.caf") == 0 ]]'

# --- Caso E: audio illeggibile, niente .m4a: i file grezzi restano ---
E="$CALL_REGISTRAZIONI/2026-11-23_10-00-00"; mkdir -p "$E"
print -r -- '{"inizio_sistema": 100.0, "inizio_microfono": 100.0}' >"$E/inizio.json"
print -r -- "non è audio" >"$E/sistema.caf"
print -r -- '{"transcription":[{"offsets":{"from":1000,"to":3000},"text":" ciao"}]}' >"$E/sistema.json"
CALL_CLAUDE="$B/tests/finto_claude.sh" "$B/call" trascrivi "$E" "Audio Rotto" >/dev/null 2>&1
ok "E: trascrizione nel vault" '[[ -s "$CALL_DESTINAZIONE/2026-11-23 Trascrizione call Audio Rotto.txt" ]]'
ok "E: file grezzi tenuti" '[[ -s "$E/sistema.caf" ]]'

rm -rf "${T:?}"
echo "Errori: $errori"
exit $(( errori > 0 ))
