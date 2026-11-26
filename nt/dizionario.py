"""Dizionario personale che impara: termini da suggerire a Whisper e sostituzioni "sbagliato → giusto".

File: dati/dizionario.json =
  {"termini": [{"testo", "usi", "ultimo"}],
   "sostituzioni": [{"da", "a", "usi", "origine"}],
   "suggerimenti": [{"da", "a", "call"}]}
Le sostituzioni si applicano a parola intera, senza badare alle maiuscole. Nessuna regola entra
da sola: i suggerimenti (dalla rilettura di Claude) aspettano l'ok dell'utente.
"""
import difflib
import re
import string
import time
import unicodedata
from pathlib import Path

from nt import dati

FRASE_ESEMPIO = "Ciao, come stai? Bene, grazie. Ti mando il preventivo entro venerdì."
CARTELLE_TERMINI = ("Clienti", "Persone", "Prodotti", "Siti", "Fornitori")
ESCLUSE = ("90 Fonti", "05 Archivio")
PUNTEGGIATURA = string.punctuation + "«»“”‘’…"


def _file() -> Path:
    return dati.CARTELLA_DATI / "dizionario.json"


def carica() -> dict:
    d = dati.leggi_json(_file(), {})
    if not isinstance(d, dict):
        d = {}
    for k in ("termini", "sostituzioni", "suggerimenti"):
        if not isinstance(d.get(k), list):
            d[k] = []
    return d


def salva(d: dict) -> None:
    dati.scrivi_json(_file(), d)


# ---------- sostituzioni ----------

def _regex(sostituzioni):
    regole = sorted((s for s in sostituzioni if s.get("da")), key=lambda s: len(s["da"]), reverse=True)
    if not regole:
        return None, {}
    alternative = "|".join(re.escape(s["da"]) for s in regole)
    schema = re.compile(r"(?<![\w@.])(?:" + alternative + r")(?![\w@])", re.IGNORECASE)
    return schema, {s["da"].lower(): s for s in regole}


def applica(testo: str, d: dict | None = None, *, registra_usi: bool = False) -> str:
    da_file = d is None
    if d is None:
        d = carica()
    schema, per_da = _regex(d["sostituzioni"])
    if schema is None or not testo:
        return testo
    usate = []

    def sostituisci(m):
        regola = per_da.get(m.group(0).lower())
        if regola is None:
            return m.group(0)
        usate.append(regola)
        return regola["a"]

    nuovo = schema.sub(sostituisci, testo)
    if registra_usi and usate:
        adesso = time.time()
        for r in usate:
            r["usi"] = int(r.get("usi", 0)) + 1
        for t in d["termini"]:  # i termini comparsi salgono nel suggerimento a Whisper
            if re.search(r"(?<!\w)" + re.escape(t["testo"]) + r"(?!\w)", nuovo, re.IGNORECASE):
                t["usi"] = int(t.get("usi", 0)) + 1
                t["ultimo"] = adesso
        if da_file:
            salva(d)
    return nuovo


def aggiungi_sostituzione(da: str, a: str, origine: str = "manuale") -> None:
    da, a = da.strip(), a.strip()
    if not da or not a or da == a:
        return
    d = carica()
    for s in d["sostituzioni"]:
        if s["da"].lower() == da.lower():
            s["da"], s["a"] = da, a
            break
    else:
        d["sostituzioni"].append({"da": da, "a": a, "usi": 0, "origine": origine})
    d["suggerimenti"] = [s for s in d["suggerimenti"] if s["da"].lower() != da.lower()]
    salva(d)


def rimuovi_sostituzione(da: str) -> None:
    d = carica()
    d["sostituzioni"] = [s for s in d["sostituzioni"] if s["da"].lower() != da.lower()]
    salva(d)


# ---------- termini ----------

def aggiungi_termine(testo: str) -> None:
    testo = " ".join(testo.split())
    if not testo:
        return
    d = carica()
    for t in d["termini"]:
        if t["testo"].lower() == testo.lower():
            t["usi"] = int(t.get("usi", 0)) + 1
            t["ultimo"] = time.time()
            break
    else:
        d["termini"].append({"testo": testo, "usi": 1, "ultimo": time.time()})
    salva(d)


def rimuovi_termine(testo: str) -> None:
    d = carica()
    d["termini"] = [t for t in d["termini"] if t["testo"].lower() != testo.lower()]
    salva(d)


def prompt_whisper(d: dict | None = None, max_caratteri: int = 600) -> str:
    """Frase d'esempio ben punteggiata + i termini più recenti e più usati, entro max_caratteri."""
    if d is None:
        d = carica()
    termini = sorted(d["termini"], key=lambda t: (t.get("ultimo", 0), t.get("usi", 0)), reverse=True)
    testo = FRASE_ESEMPIO[:max_caratteri]
    scelti = []
    for t in termini:
        prova = testo + " " + ", ".join(scelti + [t["testo"]]) + "."
        if len(prova) > max_caratteri:
            continue
        scelti.append(t["testo"])
    return testo + (" " + ", ".join(scelti) + "." if scelti else "")


# ---------- suggerimenti ----------

def _norm(parola: str) -> str:
    """Parola senza punteggiatura ai bordi, maiuscole e accenti: per capire se è cambiata davvero."""
    p = unicodedata.normalize("NFD", parola.strip(PUNTEGGIATURA).lower())
    return "".join(c for c in p if unicodedata.category(c) != "Mn")


def suggerimenti_da_confronto(grezzo: str, riletto: str) -> list[tuple[str, str]]:
    """Parole o brevi gruppi (max 4 parole) cambiati tra grezzo e riletto.

    Si confrontano le parole senza punteggiatura e maiuscole: se cambiano solo quelle, niente coppia.
    """
    a, b = grezzo.split(), riletto.split()
    sm = difflib.SequenceMatcher(None, [_norm(x) for x in a], [_norm(x) for x in b], autojunk=False)
    coppie = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op != "replace" or i2 - i1 > 4 or j2 - j1 > 4:
            continue
        da = " ".join(a[i1:i2]).strip(PUNTEGGIATURA)
        nuovo = " ".join(b[j1:j2]).strip(PUNTEGGIATURA)
        if re.fullmatch(r"[\d.,:/ -]+", da):  # solo cifre: è formattazione, una regola farebbe danni
            continue
        if da and nuovo and _norm(da) != _norm(nuovo) and (da, nuovo) not in coppie:
            coppie.append((da, nuovo))
    return coppie


def aggiungi_suggerimenti(coppie, call_id: str) -> None:
    d = carica()
    gia = {s["da"].lower() for s in d["sostituzioni"]} | {s["da"].lower() for s in d["suggerimenti"]}
    gia |= {s["da"].lower() for s in d.get("scartati", [])}
    for da, a in coppie:
        if da.lower() in gia:
            continue
        d["suggerimenti"].append({"da": da, "a": a, "call": call_id})
        gia.add(da.lower())
    salva(d)


def approva_suggerimento(da: str) -> None:
    d = carica()
    s = next((s for s in d["suggerimenti"] if s["da"].lower() == da.lower()), None)
    if s is None:
        return
    aggiungi_sostituzione(s["da"], s["a"], origine="suggerimento")


def scarta_suggerimento(da: str) -> None:
    """Toglie il suggerimento e lo ricorda, così la stessa coppia non viene riproposta."""
    d = carica()
    tolti = [s for s in d["suggerimenti"] if s["da"].lower() == da.lower()]
    d["suggerimenti"] = [s for s in d["suggerimenti"] if s["da"].lower() != da.lower()]
    d.setdefault("scartati", []).extend({"da": s["da"], "a": s["a"]} for s in tolti)
    salva(d)


# ---------- primo riempimento dal vault ----------

def termini_dal_vault(vault: Path, fissi=()) -> list[str]:
    """Nomi delle note di clienti, persone, prodotti, siti e fornitori, più i termini fissi del profilo."""
    vault = Path(vault)
    nomi = {t for t in fissi if t}
    if not vault.is_dir():
        return sorted(nomi)
    for area in vault.iterdir():
        if not area.is_dir() or area.name in ESCLUSE or area.name.startswith("."):
            continue
        for sotto in CARTELLE_TERMINI:
            cartella = area / sotto
            if not cartella.is_dir():
                continue
            for md in cartella.rglob("*.md"):
                nome = re.sub(r"\s*\([^)]*\)\s*$", "", md.stem).strip()
                if not nome or re.match(r"^\d{4}-\d{2}", nome) or nome.lower().startswith("guida di stile"):
                    continue
                nomi.add(nome)
    return sorted(nomi)
