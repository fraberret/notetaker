"""Dove stanno i dati del Notetaker e come si leggono e scrivono.

Tutto in ~/.config/trascrittore/dati/ (o in CALL_DATI per le prove).
"""
import json
import os
import tempfile
from pathlib import Path
from typing import Any

BASE = Path(__file__).resolve().parent.parent
CARTELLA_DATI = Path(os.environ.get("CALL_DATI", str(BASE / "dati")))
CARTELLA_DATI.mkdir(parents=True, exist_ok=True)
REGISTRAZIONI = Path(os.environ.get("CALL_REGISTRAZIONI", str(BASE / "registrazioni")))
FILE_STATO = Path(os.environ.get("CALL_STATO", str(BASE / "stato")))

FILE_IMPOSTAZIONI = CARTELLA_DATI / "impostazioni.json"

IMPOSTAZIONI_PREDEFINITE = {
    "tasto": "fn",              # "fn" oppure "option_destro"
    "suoni": True,
    "volume": 0.45,
    "microfono": "",            # "" = microfono del Mac, "auto" = predefinito del sistema, o un nome
    "domanda_call": True,
    "secondi_domanda": 6,
    "rilettura": True,
    "note": True,
    "giorni_audio": 90,         # 0 = mai
    "giorni_dettature": 0,      # 0 = mai
}

VALORI_AMMESSI = {"tasto": ("fn", "option_destro")}


def leggi_json(p: Path, vuoto) -> Any:
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception:
        return vuoto


def scrivi_json(p: Path, dati) -> None:
    """Scrittura atomica: file temporaneo nella stessa cartella, poi os.replace."""
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=p.parent, prefix="." + p.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(dati, f, ensure_ascii=False, indent=1)
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def _valore_valido(chiave: str, valore) -> bool:
    predefinito = IMPOSTAZIONI_PREDEFINITE[chiave]
    if isinstance(predefinito, bool):
        ok = isinstance(valore, bool)
    elif isinstance(predefinito, int):
        ok = isinstance(valore, int) and not isinstance(valore, bool) and valore >= 0
    elif isinstance(predefinito, float):
        ok = isinstance(valore, (int, float)) and not isinstance(valore, bool) and 0 <= valore <= 1
    else:
        ok = isinstance(valore, str)
    return ok and (chiave not in VALORI_AMMESSI or valore in VALORI_AMMESSI[chiave])


def _pulisci(grezze) -> dict:
    imp = dict(IMPOSTAZIONI_PREDEFINITE)
    if isinstance(grezze, dict):
        for k, v in grezze.items():
            if k in imp and _valore_valido(k, v):
                imp[k] = float(v) if isinstance(imp[k], float) else v
    return imp


def carica_impostazioni() -> dict:
    return _pulisci(leggi_json(FILE_IMPOSTAZIONI, {}))


def salva_impostazioni(nuove: dict) -> dict:
    """Unisce le nuove impostazioni a quelle salvate; un valore non valido lascia quello di prima."""
    imp = carica_impostazioni()
    for k, v in (nuove or {}).items():
        if k in imp and _valore_valido(k, v):
            imp[k] = float(v) if isinstance(imp[k], float) else v
    scrivi_json(FILE_IMPOSTAZIONI, imp)
    return imp


# ---------- profilo personale (solo su questo Mac, mai nel repository) ----------

FILE_PROFILO = CARTELLA_DATI / "profilo.json"

PROFILO_PREDEFINITO = {
    "nome": "l'utente",          # chi è "Io" nelle call
    "descrizione": "",           # lavoro e contesto, per i prompt di Claude
    "vault": "~/Vault",          # cartella del vault Obsidian
    "termini_fissi": [],         # termini sempre nel dizionario (marchi, nomi)
}


def carica_profilo() -> dict:
    letto = leggi_json(FILE_PROFILO, {})
    p = dict(PROFILO_PREDEFINITO)
    if isinstance(letto, dict):
        for k, v in letto.items():
            if k in p and isinstance(v, type(p[k])):
                p[k] = v
    p["vault"] = str(Path(os.path.expanduser(p["vault"])))
    return p


def compila_prompt(testo: str, **altri) -> str:
    """Sostituisce {{UTENTE}} (nome) e {{PROFILO}} (" (descrizione)") del profilo, più gli {{ALTRI}} dati."""
    p = carica_profilo()
    valori = {"UTENTE": p["nome"], "PROFILO": f" ({p['descrizione']})" if p["descrizione"] else ""}
    valori.update({k.upper(): str(v) for k, v in altri.items()})
    for k, v in valori.items():
        testo = testo.replace("{{" + k + "}}", v)
    return testo
