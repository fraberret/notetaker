#!/usr/bin/env python3
"""Trascrive la traccia di sistema un intervento alla volta, seguendo le voci riconosciute.

Uso: trascrivi_tratti.py <sistema.wav 16 kHz> <sistema.voci.json> <uscita sistema.json>
Unisce i tratti consecutivi della stessa voce, li spezza oltre i 28 secondi, trascrive ogni pezzo
con whisper-server (modello caricato una volta sola) e scrive un JSON nello stesso formato di
`whisper-cli -oj`, con in più il campo "voce" per ogni segmento.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

HOME = Path.home()
MODELLO = HOME / ".cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin"
SERVER = "/opt/homebrew/bin/whisper-server"
CURL = "/usr/bin/curl"
MAX_TRATTO = 28.0


def porta_libera():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def tratti_uniti(voci):
    uniti = []
    for v in sorted(voci, key=lambda x: x["da"]):
        if uniti and uniti[-1]["voce"] == v["voce"] and v["da"] - uniti[-1]["a"] < 1.0:
            uniti[-1]["a"] = v["a"]
        else:
            uniti.append(dict(v))
    pezzi = []
    for u in uniti:
        inizio = u["da"]
        while u["a"] - inizio > MAX_TRATTO + 5:
            pezzi.append({"da": inizio, "a": inizio + MAX_TRATTO, "voce": u["voce"]})
            inizio += MAX_TRATTO
        pezzi.append({"da": inizio, "a": u["a"], "voce": u["voce"]})
    return pezzi


def main():
    wav, voci_file, uscita = sys.argv[1], sys.argv[2], sys.argv[3]
    voci = json.loads(Path(voci_file).read_text())
    audio, sr = sf.read(wav, dtype="float32", always_2d=True)
    audio = audio[:, 0]
    pezzi = tratti_uniti(voci)

    porta = porta_libera()
    server = subprocess.Popen([SERVER, "-m", str(MODELLO), "-l", "it", "-t", "4",
                               "--host", "127.0.0.1", "--port", str(porta)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    segmenti = []
    try:
        url = f"http://127.0.0.1:{porta}/inference"
        with tempfile.TemporaryDirectory() as tmp:
            for n, p in enumerate(pezzi):
                a, b = int(max(0, p["da"] - 0.03) * sr), int(min(len(audio), (p["a"] + 0.15) * sr))
                if b - a < sr * 0.4:
                    continue
                f = os.path.join(tmp, f"p{n}.wav")
                sf.write(f, np.ascontiguousarray(audio[a:b]), sr, subtype="PCM_16")
                testo = ""
                for _ in range(60):  # il server impiega qualche secondo a partire
                    r = subprocess.run([CURL, "-s", "--max-time", "120", "-F", f"file=@{f}",
                                        "-F", "response_format=text", "-F", "temperature=0", url],
                                       capture_output=True, text=True)
                    if r.returncode == 0 and r.stdout:
                        testo = r.stdout.strip()
                        break
                    time.sleep(1)
                if testo:
                    segmenti.append({"offsets": {"from": int(p["da"] * 1000), "to": int(p["a"] * 1000)},
                                     "text": " " + " ".join(testo.split()), "voce": p["voce"]})
    finally:
        server.terminate()
        server.wait(timeout=10)
    Path(uscita).write_text(json.dumps({"transcription": segmenti}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{len(segmenti)} interventi trascritti")


if __name__ == "__main__":
    main()
