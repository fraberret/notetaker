"""Rilettura delle call con Claude: punteggiatura, "?", nomi secondo il dizionario, email, cifre.

Claude riceve la trascrizione a pezzi e deve restituire le stesse righe con gli stessi orari e
le stesse persone; se anche un solo pezzo non torna, la rilettura non vale (None).
"""
import os
import re
import subprocess
import tempfile
from pathlib import Path

from nt import dati, dizionario

BASE = Path(__file__).resolve().parent.parent
PROMPT = BASE / "prompt-rilettura.md"
PREFISSO = re.compile(r"^\[(?:\d+:)?\d{2}:\d{2}\] [^:\n]{1,60}:")


def percorso_claude() -> str:
    return os.environ.get("CALL_CLAUDE") or str(Path.home() / ".local/bin/claude")


def esegui_claude(richiesta: str, timeout: int = 600) -> str | None:
    """claude -p senza strumenti, in una cartella temporanea. None se fallisce o va in timeout."""
    comando = [percorso_claude(), "-p", "--tools", "", "--strict-mcp-config",
               "--no-session-persistence", "--output-format", "text"]
    with tempfile.TemporaryDirectory() as tmp:
        try:
            r = subprocess.run(comando, input=richiesta, capture_output=True, text=True,
                               cwd=tmp, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.strip()


def righe_di(testo: str) -> list[str]:
    """I turni di una trascrizione: blocchi separati da una riga vuota, ognuno su una riga."""
    return [" ".join(b.split()) for b in re.split(r"\n\s*\n", testo) if b.strip()]


def pezzi(righe: list[str], max_righe: int = 120) -> list[list[str]]:
    return [righe[i:i + max_righe] for i in range(0, len(righe), max_righe)]


def prefisso(riga: str) -> str | None:
    m = PREFISSO.match(riga)
    return m.group(0) if m else None


def valida(originale: list[str], riletto: list[str]) -> bool:
    if len(originale) != len(riletto):
        return False
    return all(prefisso(a) is not None and prefisso(a) == prefisso(b) for a, b in zip(originale, riletto))


def leggi_risposta(risposta: str) -> list[str]:
    """Righe della risposta di Claude: tollera tag, blocchi di codice e righe spezzate."""
    m = re.search(r"<trascrizione>\s*\n(.*?)\n\s*</trascrizione>", risposta, re.S)
    if m:
        risposta = m.group(1)
    righe = []
    for r in risposta.splitlines():
        r = r.strip()
        if not r or r.startswith("```"):
            continue
        if prefisso(r) is not None or not righe:
            righe.append(r)
        else:
            righe[-1] += " " + r
    return righe


def richiesta_per(pezzo: list[str], d: dict) -> str:
    termini = ", ".join(t["testo"] for t in d["termini"]) or "nessuno"
    regole = "\n".join(f"- {s['da']} → {s['a']}" for s in d["sostituzioni"]) or "- nessuna"
    return (dati.compila_prompt(PROMPT.read_text(encoding="utf-8").strip())
            + "\n\nDizionario: termini da scrivere così: " + termini
            + "\nSostituzioni (sbagliato → giusto):\n" + regole
            + "\n\n<trascrizione>\n" + "\n\n".join(pezzo) + "\n</trascrizione>\n")


def rileggi(testo: str, esegui=esegui_claude) -> str | None:
    d = dizionario.carica()
    righe = righe_di(testo)
    if not righe:
        return None
    risultato = []
    for pezzo in pezzi(righe):
        risposta = esegui(richiesta_per(pezzo, d))
        if not risposta:
            return None
        nuove = leggi_risposta(risposta)
        if not valida(pezzo, nuove):
            return None
        risultato.extend(nuove)
    finale = dizionario.applica("\n\n".join(risultato), d)
    return finale + "\n"
