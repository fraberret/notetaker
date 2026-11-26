#!/usr/bin/env python3
"""Disegna l'icona del Notetaker: microfono bianco su fondo #121216, angoli arrotondati.

Uso: icona.py <cartella .iconset>   (crea tutti i PNG che servono a iconutil)
Solo numpy e la libreria standard: il disegno è fatto con forme semplici e sovracampionamento.
"""
import struct
import sys
import zlib
from pathlib import Path

import numpy as np

FONDO = np.array([0x12, 0x12, 0x16], np.float32)
ROSSO = np.array([0xff, 0x4d, 0x4d], np.float32)
BIANCO = np.array([0xf2, 0xf2, 0xf5], np.float32)


def rett_arrotondato(x, y, cx, cy, mw, mh, r):
    dx = np.maximum(np.abs(x - cx) - (mw - r), 0)
    dy = np.maximum(np.abs(y - cy) - (mh - r), 0)
    return dx * dx + dy * dy <= r * r


def disegna(lato: int) -> np.ndarray:
    ss = 4
    n = lato * ss
    y, x = (np.mgrid[0:n, 0:n] + 0.5) / n  # coordinate 0..1
    # Superficie dell'icona come le app macOS: un po' di margine e angoli continui.
    m = 0.1
    fondo = rett_arrotondato(x, y, 0.5, 0.5, 0.5 - m, 0.5 - m, 0.185)
    # Microfono: capsula, archetto a U, asta e base.
    capsula = rett_arrotondato(x, y, 0.5, 0.40, 0.085, 0.165, 0.085)
    r = np.hypot(x - 0.5, y - 0.44)
    arco = (np.abs(r - 0.165) <= 0.022) & (y >= 0.44)
    lati = (np.abs(np.abs(x - 0.5) - 0.165) <= 0.022) & (y >= 0.36) & (y <= 0.44)
    asta = (np.abs(x - 0.5) <= 0.022) & (y >= 0.6) & (y <= 0.71)
    base = rett_arrotondato(x, y, 0.5, 0.715, 0.1, 0.022, 0.022)
    bianco = capsula | arco | lati | asta | base
    # Linguetta rossa come la pillola, sul bordo destro.
    pillola = rett_arrotondato(x, y, 0.79, 0.5, 0.022, 0.1, 0.022)

    img = np.zeros((n, n, 4), np.float32)
    img[fondo, :3] = FONDO
    img[fondo, 3] = 255
    img[fondo & bianco, :3] = BIANCO
    img[fondo & pillola, :3] = ROSSO
    img = img.reshape(lato, ss, lato, ss, 4).mean(axis=(1, 3))
    # Colore non premoltiplicato sui bordi.
    a = img[..., 3:4]
    img[..., :3] = np.where(a > 0, img[..., :3] * 255 / np.maximum(a, 1e-6), 0)
    return np.clip(img + 0.5, 0, 255).astype(np.uint8)


def scrivi_png(p: Path, img: np.ndarray):
    h, w, _ = img.shape
    righe = b"".join(b"\x00" + img[i].tobytes() for i in range(h))

    def blocco(tipo, dati):
        return struct.pack(">I", len(dati)) + tipo + dati + struct.pack(">I", zlib.crc32(tipo + dati) & 0xffffffff)

    p.write_bytes(b"\x89PNG\r\n\x1a\n" + blocco(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                  + blocco(b"IDAT", zlib.compress(righe, 9)) + blocco(b"IEND", b""))


def main():
    cartella = Path(sys.argv[1])
    cartella.mkdir(parents=True, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        scrivi_png(cartella / f"icon_{base}x{base}.png", disegna(base))
        scrivi_png(cartella / f"icon_{base}x{base}@2x.png", disegna(base * 2))


if __name__ == "__main__":
    main()
