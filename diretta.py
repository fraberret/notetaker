#!/usr/bin/env python3
"""Diretta della call: legge sistema.caf e microfono.caf mentre crescono e scrive diretta.jsonl.

Uso: diretta.py <cartella della registrazione>
Ogni 2 secondi prende l'audio nuovo, lo taglia sulle pause, lo trascrive con Parakeet e aggiunge
righe {"s": secondi dall'inizio, "chi": "Io"|"Altri", "testo": ...}. Se resta indietro di oltre
30 secondi salta avanti. Si chiude pulito con SIGTERM.
"""
import difflib
import json
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from nt import dizionario  # noqa: E402
from nt.caf import LettoreCaf  # noqa: E402
from nt.diretta import (FREQ, Riconoscitore, Segmentatore, dentro_dettatura, epoca_microfono,  # noqa: E402
                        intervalli_dettature, ricampiona)

INTERVALLO_S = 2.0
MAX_ATTESA_S = 30.0
TIENI_S = 5.0

fermati = False


def ferma(*_):
    global fermati
    fermati = True


class Traccia:
    def __init__(self, cartella: Path, file: str, chi: str):
        self.lettore = LettoreCaf(cartella / file)
        self.chi = chi
        self.seg = Segmentatore(FREQ)
        self.base_s = 0.0  # secondi di audio prima del segmentatore attuale (salti compresi)

    def pezzi(self):
        nuovi = self.lettore.leggi_nuovi()
        if not len(nuovi) or not self.lettore.frequenza:
            return []
        audio = ricampiona(nuovi, self.lettore.frequenza)
        if len(audio) > MAX_ATTESA_S * FREQ:  # troppo indietro: si salta avanti
            saltati = len(audio) - int(TIENI_S * FREQ)
            self.base_s += self.seg.posizione * Segmentatore.FINESTRA_S + len(self.seg.resto) / FREQ + saltati / FREQ
            self.seg = Segmentatore(FREQ)
            audio = audio[saltati:]
            print(f"{self.chi}: salto avanti di {saltati / FREQ:.0f} s", flush=True)
        return [(self.base_s + inizio, p) for inizio, p in self.seg.aggiungi_con_tempi(audio)]


def main():
    cartella = Path(sys.argv[1])
    signal.signal(signal.SIGTERM, ferma)
    signal.signal(signal.SIGINT, ferma)
    try:
        os.nice(10)
    except OSError:
        pass
    riconoscitore = Riconoscitore(num_threads=2)
    tracce = [Traccia(cartella, "sistema.caf", "Altri"), Traccia(cartella, "microfono.caf", "Io")]
    uscita = cartella / "diretta.jsonl"
    recenti_altri = []  # (secondi, testo) per non ripetere come "Io" l'eco delle casse
    print("Diretta avviata", flush=True)
    with open(uscita, "a", encoding="utf-8") as f:
        while not fermati:
            giro = time.monotonic()
            d = dizionario.carica()
            dettature = intervalli_dettature(cartella)
            for t in tracce:
                for inizio, pezzo in t.pezzi():
                    if fermati:
                        break
                    if t.chi == "Io" and dettature:  # dettato alla pillola: non è parte della call
                        e0 = epoca_microfono(cartella)
                        if dentro_dettatura(e0 + inizio, e0 + inizio + len(pezzo) / FREQ, dettature):
                            continue
                    testo = dizionario.applica(riconoscitore.trascrivi(pezzo), d).strip()
                    if not testo:
                        continue
                    if t.chi == "Altri":
                        recenti_altri.append((inizio, testo))
                        recenti_altri[:] = [x for x in recenti_altri if inizio - x[0] < 30]
                    elif any(abs(inizio - s) < 15 and
                             difflib.SequenceMatcher(None, testo.lower(), x.lower()).ratio() > 0.6
                             for s, x in recenti_altri):
                        continue
                    f.write(json.dumps({"s": round(inizio, 1), "chi": t.chi, "testo": testo},
                                       ensure_ascii=False) + "\n")
                    f.flush()
            attesa = INTERVALLO_S - (time.monotonic() - giro)
            while attesa > 0 and not fermati:
                time.sleep(min(0.2, attesa))
                attesa -= 0.2
    print("Diretta chiusa", flush=True)


if __name__ == "__main__":
    main()
