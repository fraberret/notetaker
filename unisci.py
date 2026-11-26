#!/usr/bin/env python3
"""Unisce le trascrizioni di microfono e sistema in un'unica conversazione a turni.

Uso: unisci.py <cartella> <nome-interlocutore> <file-di-uscita>
Nella cartella si aspetta microfono.json e/o sistema.json (output -oj di whisper-cli),
inizio.json (istante del primo campione di ciascuna traccia) e, se c'è, sistema.voci.json
(chi parla nella traccia di sistema, da voci.py). Con più voci le persone diventano
"Persona 1", "Persona 2"... in ordine di intervento; con una sola voce si usa il nome dato.
"""
import difflib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nt.dettature_call import dentro_dettatura, epoca_microfono, intervalli_dettature  # noqa: E402

RUMORI = {"[Musica]", "[MUSICA]", "[Applausi]", "...", "[Risate]", "(risate)"}


def carica(percorso: Path, chi: str, scarto_ms: float):
    if not percorso.exists():
        return []
    dati = json.loads(percorso.read_text(encoding="utf-8"))
    segmenti = []
    for s in dati.get("transcription", []):
        testo = s.get("text", "").strip()
        if not testo or testo in RUMORI:
            continue
        segmenti.append({"chi": chi, "da": s["offsets"]["from"] + scarto_ms,
                         "a": s["offsets"]["to"] + scarto_ms, "testo": testo, "voce": s.get("voce")})
    return segmenti


def assegna_voci(segmenti, voci, scarto_ms, nome):
    """Dà a ogni pezzo della traccia di sistema la voce che si sovrappone di più."""
    if not voci:
        return
    tratti = [(v["da"] * 1000 + scarto_ms, v["a"] * 1000 + scarto_ms, v["voce"]) for v in voci]
    distinte = []
    for _, _, v in tratti:
        if v not in distinte:
            distinte.append(v)
    if len(distinte) <= 1:
        return  # una sola persona: resta il nome dato
    etichetta = {v: f"Persona {i + 1}" for i, v in enumerate(distinte)}
    for s in segmenti:
        if s.get("voce") in etichetta:  # già trascritto per intervento: la voce è nota
            s["chi"] = etichetta[s["voce"]]
            continue
        punteggio = {}
        for da, a, v in tratti:
            sovrapp = min(s["a"], a) - max(s["da"], da)
            if sovrapp > 0:
                punteggio[v] = punteggio.get(v, 0) + sovrapp
        if punteggio:
            s["chi"] = etichetta[max(punteggio, key=punteggio.get)]
        else:  # nessuna sovrapposizione: la voce più vicina nel tempo
            vicina = min(tratti, key=lambda t: min(abs(s["da"] - t[1]), abs(t[0] - s["a"])))
            s["chi"] = etichetta[vicina[2]]


def parole(t: str) -> list[str]:
    return "".join(c if c.isalnum() else " " for c in t.lower()).split()


def simile(a: str, b: str) -> float:
    """Somiglianza tra un pezzo del microfono (a) e uno del sistema (b). Se il microfono ha ripreso
    solo una parte della frase delle casse (almeno 4 parole, tutte di fila dentro b), conta come uguale."""
    pa, pb = parole(a), parole(b)
    if len(pa) >= 4 and len(pa) < len(pb):
        blocco = difflib.SequenceMatcher(None, pa, pb, autojunk=False).find_longest_match(0, len(pa), 0, len(pb))
        if blocco.size >= 0.8 * len(pa):
            return 1.0
    return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()


def mmss(ms):
    sec = int(ms // 1000)
    h, r = divmod(sec, 3600)
    m, s = divmod(r, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main():
    cartella, nome, uscita = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    inizio = {}
    if (cartella / "inizio.json").exists():
        inizio = json.loads((cartella / "inizio.json").read_text())
    i_sis, i_mic = inizio.get("inizio_sistema"), inizio.get("inizio_microfono")
    presenti = [x for x in (i_sis, i_mic) if x is not None]
    base = min(presenti) if presenti else 0.0
    scarto_sis = ((i_sis - base) * 1000) if i_sis is not None else 0.0
    scarto_mic = ((i_mic - base) * 1000) if i_mic is not None else 0.0

    sistema = carica(cartella / "sistema.json", nome, scarto_sis)
    microfono = carica(cartella / "microfono.json", "Io", scarto_mic)
    # Le dettature fatte alla pillola durante la call restano solo nello storico delle dettature.
    dettature = intervalli_dettature(cartella)
    if dettature:
        e0 = epoca_microfono(cartella)
        prima = len(microfono)
        microfono = [m for m in microfono if not dentro_dettatura(
            e0 + (m["da"] - scarto_mic) / 1000, e0 + (m["a"] - scarto_mic) / 1000, dettature)]
        print(f"{prima - len(microfono)} pezzi tolti perché dettati alla pillola")

    voci_file = cartella / "sistema.voci.json"
    voci = json.loads(voci_file.read_text()) if voci_file.exists() else []
    assegna_voci(sistema, voci, scarto_sis, nome)

    # Con le casse il microfono riprende anche gli altri: si scartano i pezzi del microfono
    # quasi uguali a un pezzo del sistema detto nello stesso momento.
    # Si guarda la sovrapposizione degli intervalli, non solo l'inizio: con il filtro dei silenzi
    # Whisper può far cominciare il pezzo del microfono parecchi secondi prima della frase.
    tenuti = [m for m in microfono if not any(
        m["da"] <= s["a"] + 2000 and m["a"] >= s["da"] - 2000 and simile(m["testo"], s["testo"]) > 0.6
        for s in sistema)]

    turni = []
    for s in sorted(sistema + tenuti, key=lambda s: s["da"]):
        if turni and turni[-1]["chi"] == s["chi"] and s["da"] - turni[-1]["a"] < 4000:
            turni[-1]["testo"] += " " + s["testo"]
            turni[-1]["a"] = s["a"]
        else:
            turni.append(dict(s))

    righe = [f"[{mmss(t['da'])}] {t['chi']}: {t['testo']}" for t in turni]
    uscita.write_text("\n\n".join(righe) + "\n", encoding="utf-8")
    persone = sorted({t["chi"] for t in turni})
    print(f"{len(turni)} turni, persone: {', '.join(persone)}; {len(microfono) - len(tenuti)} pezzi d'eco scartati")


if __name__ == "__main__":
    main()
