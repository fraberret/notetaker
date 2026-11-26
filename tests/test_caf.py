import subprocess

import numpy as np


def crea_caf(percorso, secondi=3.0, sr=48000):
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    f"sine=frequency=440:sample_rate={sr}:duration={secondi}",
                    "-ac", "1", "-c:a", "pcm_f32le", str(percorso)], check=True)


def test_caf_crescente(tmp_path):
    from nt.caf import LettoreCaf
    pieno = tmp_path / "pieno.caf"
    crea_caf(pieno)
    byte = pieno.read_bytes()
    file = tmp_path / "sistema.caf"
    inizio_dati = byte.index(b"data") + 12 + 4
    meta = inizio_dati + (len(byte) - inizio_dati) // 2 + 3  # anche a metà di un campione
    file.write_bytes(byte[:meta])
    l = LettoreCaf(file)
    primi = l.leggi_nuovi()
    assert l.frequenza == 48000
    assert primi.dtype == np.float32
    assert abs(len(primi) - 72000) < 48000 * 0.02
    file.write_bytes(byte)
    resto = l.leggi_nuovi()
    assert abs((len(primi) + len(resto)) - 144000) <= 144000 * 0.01
    assert len(l.leggi_nuovi()) == 0
    assert np.abs(resto).max() > 0.1


def test_caf_mancante(tmp_path):
    from nt.caf import LettoreCaf
    l = LettoreCaf(tmp_path / "non-ce.caf")
    assert len(l.leggi_nuovi()) == 0
    (tmp_path / "non-ce.caf").write_bytes(b"caff\x00\x01")  # appena creato, header incompleto
    assert len(l.leggi_nuovi()) == 0
