#!/bin/zsh
# Finto whisper-cli per le prove: scrive <-of>.json con una frase, senza modello.
of=""
while (( $# )); do [[ "$1" == "-of" ]] && { of="$2"; shift; }; shift; done
print -r -- '{"transcription":[{"offsets":{"from":500,"to":1500},"text":" pronto mi senti"}]}' >"$of.json"
