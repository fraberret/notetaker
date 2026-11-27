# Notetaker

Dettatura e trascrizione delle call **in locale su macOS**, con un'app per ritrovare tutto e un dizionario personale che impara dalle correzioni. Pensato per chi lavora in italiano e tiene gli appunti in un vault Obsidian.

- **Dettatura**: tieni premuto Fn (o Option destro), parli, il testo viene incollato dove c'è il cursore. Whisper gira sul Mac; ogni dettatura passa dal dizionario e finisce in uno storico.
- **Call**: registra il microfono e l'audio della call, mostra il testo **in diretta** mentre si parla, poi fa la versione finale con le persone separate ("Io" e il nome dato; con più nomi, "Marco, Giulia", riconosce chi parla: "Persona 1", "Persona 2"…), la fa rileggere a Claude (punteggiatura, "?", nomi, email, cifre) e scrive le note della call.
- **App Notetaker**: un'app sola, sempre accesa con un'icona nella barra dei menu e una **pillola** sul bordo destro dello schermo (dettatura, domanda "la trascrivo?" quando un'app di call usa il microfono, pulsante per registrare). Nella finestra: elenco delle call con audio (clic sull'orario = salto nell'audio), riassunto, trascrizione a colori per persona, correzioni, "Chiedi a Claude"; storico delle dettature; dizionario; impostazioni; ricerca.

Tutto resta sul Mac. L'unica cosa che esce è il **testo delle call** mandato a Claude per la rilettura, le note e le domande (si può spegnere nelle impostazioni).

## Come funziona

| Pezzo | Cosa fa |
|---|---|
| `registra.swift` | registra microfono (AVAudioEngine, con la modalità voce quando un'app di chiamata come WhatsApp toglie il microfono alle altre) e audio di sistema (ScreenCaptureKit) su due file |
| `call` | comando zsh: `call avvia "Nome"`, `call ferma`, `call stato`, `call trascrivi`, `call riprova`, `call pulisci` |
| `diretta.py`, `nt/diretta.py`, `nt/caf.py` | diretta durante la call: legge i file mentre crescono, taglia sulle pause, trascrive con Parakeet |
| `voci.py`, `trascrivi_tratti.py`, `unisci.py` | versione finale: con più persone chi parla (sherpa-onnx) e trascrizione per intervento (whisper.cpp), turni "[mm:ss] Chi: testo" |
| `nt/rilettura.py`, `prompt-rilettura.md` | rilettura con Claude a pezzi, con controllo che righe, orari e persone restino uguali |
| `nt/dizionario.py` | sostituzioni "sbagliato → giusto" a parola intera e termini suggeriti a Whisper; le regole nuove entrano solo con il tuo ok |
| `app/` | motore locale (`server.py`, solo 127.0.0.1 con gettone), interfaccia (`index.html`), app macOS (`Notetaker.swift`, `main.swift`, `build.sh`) |
| `app/pillola/` | la pillola in Swift: tasto di dettatura, cattura, whisper-server, dizionario e incolla, domanda e registrazione delle call, scorciatoie |
| `hammerspoon/init.lua` | versione precedente della pillola (Hammerspoon), non più necessaria |
| `it.notetaker.manutenzione.plist` | ogni 30 minuti: riprova le riletture in attesa, cancella gli audio più vecchi di quanto impostato |

Se Claude non risponde, la call aspetta e si riprova; dopo 24 ore entra la versione grezza, segnata "da rileggere". Le trascrizioni nel vault non vengono mai modificate: correzioni e nomi stanno nei dati dell'app.

## Requisiti

- Mac con Apple Silicon, macOS 15 o successivo
- [Homebrew](https://brew.sh): `brew install whisper-cpp ffmpeg uv`
- [Claude Code](https://claude.com/claude-code) (`claude` in `~/.local/bin`) per rilettura e note; facoltativo
- Microfono: di base quello del Mac, come consiglia anche Wispr Flow (un paio di AirPods collegate ma non indossate diventerebbero il predefinito e non sentirebbero niente); si cambia nelle impostazioni dell'app. Se il microfono non manda audio, la pillola avvisa.
- Permessi di macOS per Notetaker: Accessibilità (tasto di dettatura, Esc, incolla), Microfono, Registrazione schermo e audio di sistema (registrazione delle call)

### Modelli

- Whisper: `ggml-large-v3-turbo-q5_0.bin` e il filtro dei silenzi `ggml-silero-v5.1.2.bin` in `~/.cache/whisper-cpp/` (dai modelli di whisper.cpp)
- In `modelli/` (dai modelli pubblicati da sherpa-onnx):
  - `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/` per la diretta
  - `sherpa-onnx-pyannote-segmentation-3-0/` per capire chi parla
  - `voce.onnx`: un modello di impronte vocali 3D-Speaker

## Installazione

```zsh
git clone https://github.com/fraberret/notetaker ~/.config/trascrittore
cd ~/.config/trascrittore
zsh installa.sh
```

Poi:

1. scrivi i tuoi dati in `dati/profilo.json` (nome, una riga su di te per i prompt di Claude, cartella del vault, termini fissi del dizionario);
2. facoltativo ma consigliato, prima di `installa.sh` o di `zsh app/build.sh`: `zsh app/certificato.sh` crea un certificato di firma locale ("Notetaker locale"); con quello macOS non richiede i permessi a ogni ricompilazione;
3. apri Notetaker da `~/Applications` e dai i permessi: se manca l'Accessibilità, il menu dell'icona lo dice e porta alle Impostazioni.

Il Notetaker parte da solo al login (si spegne dalle impostazioni dell'app). Chiudere la finestra la nasconde; **Cmd+Q** spegne tutto, pillola compresa. Scorciatoie: Ctrl+Option+Cmd+R avvia o ferma la registrazione di una call, Ctrl+Option+Cmd+N apre la finestra; clic destro sulla pillola apre la finestra.

Le trascrizioni vanno in `<vault>/90 Fonti/Trascrizioni/`, le note delle call in `<vault>/00 Inbox/`. Tutti i dati dell'app (dettature, dizionario, correzioni, impostazioni) stanno in `dati/`, fuori dal repository.

## Prove

```zsh
venv/bin/python -m pytest -q
zsh tests/test_pipeline.sh
zsh tests/test_swift.sh     # logica della pillola: tasto, pulizia del testo, impostazioni
zsh tests/test_pillola.sh   # con l'app accesa: una dettatura vera, detta dagli altoparlanti, senza incollare
```

Le prove usano sempre cartelle temporanee (`CALL_DESTINAZIONE`, `CALL_NOTE_DESTINAZIONE`, `CALL_DATI`, `CALL_REGISTRAZIONI`, `CALL_STATO`) e un Claude finto (`CALL_CLAUDE=tests/finto_claude.sh`); per l'app si passano con `open -n --env NOME=valore ~/Applications/Notetaker.app`.

La pillola si pilota con comandi `notetaker://`, accettati solo dopo `open -g "notetaker://senza-incolla?secondi=120"` e fino a quella scadenza (così una prova dimenticata non blocca la dettatura): `mostra?stato=domanda`, `foto?file=/tmp/p.png`, `detta`, `fine`, `annulla`. Lo stato si legge in `stato-pillola.json`.

## Nota sul consenso

Prima di trascrivere una call bisogna chiedere il consenso a chi partecipa. Il programma lo ricorda, ma chiederlo resta compito tuo.

## Licenza

MIT, vedi [LICENSE](LICENSE).
