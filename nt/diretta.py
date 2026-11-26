"""Diretta durante la call: taglio dell'audio sulle pause e trascrizione veloce con Parakeet.

È una bozza: la versione finale arriva dopo, con Whisper turbo, voci separate e rilettura.
"""
from pathlib import Path

import numpy as np

from nt.dettature_call import dentro_dettatura, epoca_microfono, intervalli_dettature  # noqa: F401

BASE = Path(__file__).resolve().parent.parent
PARAKEET = BASE / "modelli" / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
FREQ = 16000


def ricampiona(campioni: np.ndarray, frequenza: int, verso: int = FREQ) -> np.ndarray:
    """A 16 kHz. Da 48 kHz (multiplo intero) media su 3 campioni, altrimenti interpolazione lineare."""
    campioni = np.asarray(campioni, dtype=np.float32)
    if frequenza == verso or len(campioni) == 0:
        return campioni
    if frequenza % verso == 0:
        k = frequenza // verso
        n = len(campioni) // k * k
        return campioni[:n].reshape(-1, k).mean(axis=1).astype(np.float32)
    n = int(round(len(campioni) * verso / frequenza))
    x = np.linspace(0, len(campioni) - 1, n)
    return np.interp(x, np.arange(len(campioni)), campioni).astype(np.float32)


class Segmentatore:
    """Accumula l'audio e restituisce i pezzi chiusi da una pausa o lunghi max_s.

    La voce si riconosce dall'energia (RMS su finestre di 30 ms) sopra una soglia che si adatta
    al rumore di fondo degli ultimi secondi.
    """

    FINESTRA_S = 0.03
    MIN_S = 0.4
    PRIMA_S = 0.2  # un po' di audio prima dell'inizio della voce, per non mangiare la prima sillaba

    def __init__(self, frequenza: int, pausa_s: float = 0.6, max_s: float = 15.0):
        self.f = frequenza
        self.finestra = max(1, int(frequenza * self.FINESTRA_S))
        self.pausa = int(pausa_s / self.FINESTRA_S)
        self.max_finestre = int(max_s / self.FINESTRA_S)
        self.prima = int(self.PRIMA_S / self.FINESTRA_S)
        self.resto = np.zeros(0, np.float32)   # campioni che non fanno ancora una finestra
        self.storia = []                       # RMS delle ultime finestre, per la soglia
        self.pezzo = []                        # finestre del pezzo aperto
        self.vocali = 0                        # finestre con voce nel pezzo aperto
        self.silenzio = 0                      # finestre di silenzio di fila nel pezzo aperto
        self.attesa = []                       # finestre prima della voce
        self.posizione = 0                     # finestre lette dall'inizio
        self.inizio_pezzo = 0

    def _soglia(self) -> float:
        if len(self.storia) < 10:
            return 0.01
        h = np.array(self.storia[-330:])  # circa 10 s
        return float(max(0.003, min(2.5 * np.percentile(h, 20), 0.5 * np.percentile(h, 90))))

    def _chiudi_pezzo(self, uscita):
        if self.pezzo and self.vocali * self.FINESTRA_S >= self.MIN_S:
            uscita.append((self.inizio_pezzo * self.FINESTRA_S, np.concatenate(self.pezzo)))
        self.pezzo, self.vocali, self.silenzio = [], 0, 0

    def aggiungi_con_tempi(self, campioni: np.ndarray) -> list[tuple[float, np.ndarray]]:
        """Come aggiungi, ma con l'inizio di ogni pezzo in secondi dall'inizio dell'audio."""
        dati = np.concatenate([self.resto, np.asarray(campioni, np.float32)])
        n = len(dati) // self.finestra
        self.resto = dati[n * self.finestra:]
        uscita = []
        for i in range(n):
            w = dati[i * self.finestra:(i + 1) * self.finestra]
            rms = float(np.sqrt(np.mean(w * w)))
            voce = rms > self._soglia()
            self.storia.append(rms)
            if len(self.storia) > 2000:
                del self.storia[:1000]
            if self.pezzo:
                self.pezzo.append(w)
                if voce:
                    self.vocali += 1
                    self.silenzio = 0
                else:
                    self.silenzio += 1
                if self.silenzio >= self.pausa:
                    # La coda di silenzio non serve: se ne tiene solo un pezzetto.
                    tieni = len(self.pezzo) - self.silenzio + min(self.silenzio, 5)
                    self.pezzo = self.pezzo[:tieni]
                    self._chiudi_pezzo(uscita)
                elif len(self.pezzo) >= self.max_finestre:
                    self._chiudi_pezzo(uscita)
                    self.inizio_pezzo = self.posizione + 1
                    self.pezzo = []
            elif voce:
                self.inizio_pezzo = self.posizione - len(self.attesa)
                self.pezzo = self.attesa + [w]
                self.vocali, self.silenzio = 1, 0
                self.attesa = []
            else:
                self.attesa.append(w)
                if len(self.attesa) > self.prima:
                    self.attesa.pop(0)
            self.posizione += 1
        # Dopo un taglio per lunghezza il pezzo successivo continua subito.
        return uscita

    def aggiungi(self, campioni: np.ndarray) -> list[np.ndarray]:
        return [p for _, p in self.aggiungi_con_tempi(campioni)]

    def chiudi_con_tempi(self) -> list[tuple[float, np.ndarray]]:
        uscita = []
        if self.pezzo and len(self.resto):
            self.pezzo.append(self.resto)
        self.resto = np.zeros(0, np.float32)
        self._chiudi_pezzo(uscita)
        return uscita

    def chiudi(self) -> list[np.ndarray]:
        return [p for _, p in self.chiudi_con_tempi()]


class Riconoscitore:
    """Parakeet TDT 0.6B v3 int8 con sherpa-onnx, 2 thread per non disturbare la videochiamata."""

    def __init__(self, num_threads: int = 2):
        import sherpa_onnx
        self.r = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(PARAKEET / "encoder.int8.onnx"),
            decoder=str(PARAKEET / "decoder.int8.onnx"),
            joiner=str(PARAKEET / "joiner.int8.onnx"),
            tokens=str(PARAKEET / "tokens.txt"),
            num_threads=num_threads,
            model_type="nemo_transducer",
            decoding_method="greedy_search",
        )

    def trascrivi(self, campioni_16k: np.ndarray) -> str:
        s = self.r.create_stream()
        s.accept_waveform(FREQ, np.ascontiguousarray(campioni_16k, dtype=np.float32))
        self.r.decode_stream(s)
        return " ".join(s.result.text.split())
