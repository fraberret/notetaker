#!/usr/bin/env python3
"""Riconosce chi parla nella traccia dell'audio della call (tutte le altre persone insieme).

Uso: voci.py <file.wav 16 kHz mono> <uscita.json> [numero di persone, se noto]
Scrive una lista di tratti {"da": secondi, "a": secondi, "voce": n} con n da 0 in su.
Tutto in locale con sherpa-onnx (segmentazione pyannote + impronte vocali 3D-Speaker).
"""
import json
import sys
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf

MODELLI = Path(__file__).resolve().parent / "modelli"


def main():
    wav, uscita = sys.argv[1], sys.argv[2]
    quante = int(sys.argv[3]) if len(sys.argv) > 3 else -1

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(MODELLI / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx")),
            num_threads=4,
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(MODELLI / "voce.onnx"), num_threads=4),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=quante, threshold=0.6),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not config.validate():
        sys.exit("Configurazione dei modelli non valida")
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)

    audio, sr = sf.read(wav, dtype="float32", always_2d=True)
    audio = audio[:, 0]
    if sr != sd.sample_rate:
        sys.exit(f"Serve audio a {sd.sample_rate} Hz, non {sr}")
    if len(audio) < sr:  # meno di un secondo: niente da riconoscere
        Path(uscita).write_text("[]")
        return

    risultato = sd.process(np.ascontiguousarray(audio)).sort_by_start_time()
    tratti = [{"da": round(r.start, 2), "a": round(r.end, 2), "voce": int(r.speaker)} for r in risultato]
    Path(uscita).write_text(json.dumps(tratti, indent=1))
    print(f"{len({t['voce'] for t in tratti})} voci, {len(tratti)} tratti")


if __name__ == "__main__":
    main()
