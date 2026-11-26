"""Dettature fatte durante una call: il microfono è condiviso, quindi quello che l'utente detta alla
pillola finirebbe anche nella call. La pillola annota gli intervalli (secondi epoch) in
<cartella della call>/dettature-in-call.jsonl; diretta e trascrizione finale tolgono i pezzi "Io" lì dentro.
Solo libreria standard: lo usa anche unisci.py, che gira con il Python di sistema.
"""
import json
import os
import time
from pathlib import Path

MARGINE_S = 1.0


def intervalli_dettature(cartella: Path) -> list[tuple[float, float]]:
    """Una riga {"da"} all'inizio della dettatura e una {"da", "a"} alla fine: senza fine è ancora in corso."""
    per_inizio = {}
    try:
        righe = (Path(cartella) / "dettature-in-call.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for r in righe:
        try:
            x = json.loads(r)
            da = float(x["da"])
            a = float(x["a"]) if x.get("a") is not None else float("inf")
        except (ValueError, KeyError, TypeError):
            continue
        per_inizio[da] = min(per_inizio.get(da, float("inf")), a)
    return sorted(per_inizio.items())


def dentro_dettatura(da: float, a: float, intervalli, margine: float = MARGINE_S) -> bool:
    return any(da < fine + margine and a > inizio - margine for inizio, fine in intervalli)


def epoca_microfono(cartella: Path) -> float:
    """Quando è iniziata la traccia del microfono: nascita di microfono.caf, altrimenti il nome della cartella."""
    cartella = Path(cartella)
    try:
        return os.stat(cartella / "microfono.caf").st_birthtime
    except (OSError, AttributeError):
        pass
    try:
        return time.mktime(time.strptime(cartella.name, "%Y-%m-%d_%H-%M-%S"))
    except ValueError:
        return 0.0
