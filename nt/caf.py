"""Lettura di un file CAF mentre il registratore lo sta ancora scrivendo.

Il registratore (`registra`) scrive PCM mono (di solito float32 a 48 kHz). Il blocco `data` è
l'ultimo del file e la sua dimensione può essere -1 (sconosciuta) finché il file è aperto: si legge
fino alla fine del file, a campioni interi.
"""
import struct
from pathlib import Path

import numpy as np

VUOTO = np.zeros(0, dtype=np.float32)


class LettoreCaf:
    def __init__(self, percorso: Path):
        self.percorso = Path(percorso)
        self.frequenza = 0
        self._inizio = None      # byte dove cominciano i campioni
        self._letti = 0          # byte di campioni già restituiti
        self._dtype = None
        self._canali = 1

    def _leggi_header(self) -> bool:
        try:
            with open(self.percorso, "rb") as f:
                testa = f.read(65536)
        except OSError:
            return False
        if len(testa) < 8 or testa[:4] != b"caff":
            return False
        pos = 8
        desc = None
        while pos + 12 <= len(testa):
            tipo = testa[pos:pos + 4]
            dimensione = struct.unpack(">q", testa[pos + 4:pos + 12])[0]
            corpo = pos + 12
            if tipo == b"desc" and corpo + 32 <= len(testa):
                desc = struct.unpack(">d4sIIIII", testa[corpo:corpo + 32])
            if tipo == b"data":
                if desc is None:
                    return False
                frequenza, formato, flag, _, _, canali, bit = desc[0], desc[1], desc[2], desc[3], desc[4], desc[5], desc[6]
                if formato != b"lpcm" or canali < 1:
                    raise ValueError(f"Formato CAF non gestito: {formato!r}")
                piccolo = ">" if not (flag & 2) else "<"
                if flag & 1 and bit == 32:
                    self._dtype = np.dtype(piccolo + "f4")
                elif flag & 1 and bit == 64:
                    self._dtype = np.dtype(piccolo + "f8")
                elif bit == 16:
                    self._dtype = np.dtype(piccolo + "i2")
                elif bit == 32:
                    self._dtype = np.dtype(piccolo + "i4")
                else:
                    raise ValueError(f"Bit per campione non gestiti: {bit}")
                self.frequenza = int(frequenza)
                self._canali = canali
                self._inizio = corpo + 4  # 4 byte di "edit count" prima dei campioni
                return True
            if dimensione < 0:
                return False
            pos = corpo + dimensione
        return False

    def leggi_nuovi(self) -> np.ndarray:
        if self._inizio is None and not self._leggi_header():
            return VUOTO
        try:
            dimensione_file = self.percorso.stat().st_size
        except OSError:
            return VUOTO
        # Si legge fino in fondo al file: durante la registrazione la dimensione scritta nel blocco
        # `data` può essere -1 o non aggiornata, e il blocco `data` è sempre l'ultimo.
        fine = dimensione_file
        passo = self._dtype.itemsize * self._canali
        disponibili = (fine - self._inizio - self._letti) // passo * passo
        if disponibili <= 0:
            return VUOTO
        with open(self.percorso, "rb") as f:
            f.seek(self._inizio + self._letti)
            grezzi = f.read(disponibili)
        disponibili = len(grezzi) // passo * passo
        self._letti += disponibili
        campioni = np.frombuffer(grezzi[:disponibili], dtype=self._dtype)
        if self._dtype.kind == "i":
            campioni = campioni / float(2 ** (8 * self._dtype.itemsize - 1))
        campioni = campioni.astype(np.float32)
        if self._canali > 1:
            campioni = campioni.reshape(-1, self._canali).mean(axis=1)
        return campioni
