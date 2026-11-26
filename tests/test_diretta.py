import subprocess

import numpy as np
import soundfile as sf

SR = 16000


def tono(secondi, ampiezza=0.3):
    t = np.arange(int(secondi * SR)) / SR
    return (ampiezza * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def silenzio(secondi):
    rng = np.random.default_rng(0)
    return (rng.standard_normal(int(secondi * SR)) * 0.001).astype(np.float32)


def test_segmentatore_pause():
    from nt.diretta import Segmentatore
    s = Segmentatore(SR)
    audio = np.concatenate([tono(1), silenzio(1), tono(1)])
    pezzi = []
    for i in range(0, len(audio), 3200):  # a blocchi da 0,2 s, come arriva dal file
        pezzi += s.aggiungi(audio[i:i + 3200])
    pezzi += s.chiudi()
    assert len(pezzi) == 2
    assert all(0.9 * SR <= len(p) <= 1.8 * SR for p in pezzi)


def test_segmentatore_scarta_pezzi_corti():
    from nt.diretta import Segmentatore
    s = Segmentatore(SR)
    pezzi = s.aggiungi(np.concatenate([silenzio(1), tono(0.2), silenzio(1)])) + s.chiudi()
    assert pezzi == []


def test_segmentatore_max():
    from nt.diretta import Segmentatore
    s = Segmentatore(SR)
    pezzi = s.aggiungi(tono(40)) + s.chiudi()
    assert len(pezzi) >= 3
    assert all(len(p) <= 15 * SR for p in pezzi)
    assert abs(sum(len(p) for p in pezzi) - 40 * SR) < SR


def test_ricampiona():
    from nt.diretta import ricampiona
    assert len(ricampiona(np.zeros(48000, np.float32), 48000)) == 16000
    assert len(ricampiona(np.zeros(44100, np.float32), 44100)) == 16000


def test_riconoscitore_parla(tmp_path):
    from nt.diretta import Riconoscitore
    aiff, wav = tmp_path / "f.aiff", tmp_path / "f.wav"
    subprocess.run(["say", "-v", "Alice", "-o", str(aiff), "Buongiorno, ti mando il preventivo"], check=True)
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", "16000",
                    "-ac", "1", str(wav)], check=True)
    audio, sr = sf.read(wav, dtype="float32")
    assert "preventivo" in Riconoscitore().trascrivi(audio).lower()
