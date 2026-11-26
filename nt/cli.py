"""Comandi del Notetaker per il comando `call` e per Hammerspoon.

  python -m nt.cli rileggi <cartella>        rilegge trascrizione.txt con Claude (esce 2 se non riesce)
  python -m nt.cli applica                   stdin → stdout con il dizionario applicato
  python -m nt.cli prompt                    suggerimento iniziale per Whisper
  python -m nt.cli impostazione <chiave>     stampa un'impostazione (true/false per i sì/no)
  python -m nt.cli pulisci <cartella trascrizioni>   audio vecchi e dettature vecchie
  python -m nt.cli da-rileggere <id call>    segna una call entrata grezza nel vault
  python -m nt.cli salva-dettatura --grezzo T --finale T --app A --durata S
  python -m nt.cli profilo <chiave>          stampa un campo del profilo (dati/profilo.json)
  python -m nt.cli prompt-note <titolo> <data> <fonte>   prompt delle note della call, già compilato
"""
import argparse
import json
import shutil
import sys
import time
from pathlib import Path

from nt import dati, dizionario, rilettura

BASE = Path(__file__).resolve().parent.parent


def cmd_rileggi(cartella: Path) -> int:
    trascr = cartella / "trascrizione.txt"
    if not trascr.is_file():
        print(f"Manca {trascr}", file=sys.stderr)
        return 1
    grezzo = trascr.read_text(encoding="utf-8")
    shutil.copyfile(trascr, cartella / "trascrizione-grezza.txt")
    if not dati.carica_impostazioni()["rilettura"]:
        trascr.write_text(dizionario.applica(grezzo, registra_usi=True), encoding="utf-8")
        print("Rilettura spenta: applicato solo il dizionario")
        return 0
    riletto = rilettura.rileggi(grezzo)
    if riletto is None:
        print("Rilettura non riuscita", file=sys.stderr)
        return 2
    trascr.write_text(riletto, encoding="utf-8")
    coppie = []
    for a, b in zip(rilettura.righe_di(grezzo), rilettura.righe_di(riletto)):
        for c in dizionario.suggerimenti_da_confronto(a.split(":", 1)[-1], b.split(":", 1)[-1]):
            if c not in coppie:
                coppie.append(c)
    dizionario.aggiungi_suggerimenti(coppie, cartella.name)
    dizionario.applica(riletto, registra_usi=True)  # solo per contare gli usi
    print(f"Riletta; {len(coppie)} suggerimenti per il dizionario")
    return 0


def cmd_impostazione(chiave: str) -> int:
    imp = dati.carica_impostazioni()
    if chiave not in imp:
        print(f"Impostazione sconosciuta: {chiave}", file=sys.stderr)
        return 1
    v = imp[chiave]
    print(("true" if v else "false") if isinstance(v, bool) else v)
    return 0


def cmd_pulisci(trascrizioni: Path) -> int:
    imp = dati.carica_impostazioni()
    adesso = time.time()
    if imp["giorni_audio"] > 0 and trascrizioni.is_dir():
        limite = adesso - imp["giorni_audio"] * 86400
        registro = dati.CARTELLA_DATI / "audio-cancellati.json"
        cancellati = dati.leggi_json(registro, [])
        # Solo gli audio delle call del Notetaker, con la loro trascrizione accanto: gli altri audio
        # in 90 Fonti (incontri, vocali) restano intoccabili.
        for m4a in sorted(trascrizioni.glob("* Trascrizione call *.m4a")):
            if m4a.with_suffix(".txt").is_file() and m4a.stat().st_mtime < limite:
                m4a.unlink()
                cancellati.append({"nome": m4a.name, "quando": time.strftime("%Y-%m-%d %H:%M")})
                print(f"Audio cancellato: {m4a.name}")
        dati.scrivi_json(registro, cancellati)
    file_dett = dati.CARTELLA_DATI / "dettature.jsonl"
    if imp["giorni_dettature"] > 0 and file_dett.is_file():
        limite = adesso - imp["giorni_dettature"] * 86400
        tenute, tolte = [], 0
        for riga in file_dett.read_text(encoding="utf-8").splitlines():
            try:
                vecchia = float(json.loads(riga).get("t", adesso)) < limite
            except Exception:
                vecchia = False
            if vecchia:
                tolte += 1
            elif riga.strip():
                tenute.append(riga)
        if tolte:
            tmp = file_dett.with_suffix(".tmp")
            tmp.write_text("".join(r + "\n" for r in tenute), encoding="utf-8")
            tmp.replace(file_dett)
            print(f"Dettature cancellate: {tolte}")
    return 0


def segna_da_rileggere(call_id: str, si: bool = True) -> None:
    p = dati.CARTELLA_DATI / "da-rileggere.json"
    elenco = [x for x in dati.leggi_json(p, []) if x != call_id]
    if si:
        elenco.append(call_id)
    dati.scrivi_json(p, elenco)


def salva_dettatura(grezzo: str, finale: str, app: str, durata: float) -> None:
    """Una riga in dati/dettature.jsonl (fuori dal vault e da Git)."""
    riga = {"t": time.time(), "app": app, "grezzo": grezzo, "testo": finale, "durata": durata}
    with open(dati.CARTELLA_DATI / "dettature.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(riga, ensure_ascii=False) + "\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="nt.cli")
    sub = ap.add_subparsers(dest="comando", required=True)
    sub.add_parser("rileggi").add_argument("cartella", type=Path)
    sub.add_parser("applica")
    sub.add_parser("prompt")
    sub.add_parser("impostazione").add_argument("chiave")
    sub.add_parser("pulisci").add_argument("trascrizioni", type=Path)
    sub.add_parser("da-rileggere").add_argument("id")
    sd = sub.add_parser("salva-dettatura")
    sd.add_argument("--grezzo", required=True)
    sd.add_argument("--finale", required=True)
    sd.add_argument("--app", default="")
    sd.add_argument("--durata", type=float, default=0.0)
    sub.add_parser("profilo").add_argument("chiave")
    pn = sub.add_parser("prompt-note")
    pn.add_argument("titolo")
    pn.add_argument("data")
    pn.add_argument("fonte")
    a = ap.parse_args(argv)

    if a.comando == "rileggi":
        return cmd_rileggi(a.cartella)
    if a.comando == "applica":
        sys.stdout.write(dizionario.applica(sys.stdin.read(), registra_usi=True))
        return 0
    if a.comando == "prompt":
        print(dizionario.prompt_whisper())
        return 0
    if a.comando == "impostazione":
        return cmd_impostazione(a.chiave)
    if a.comando == "pulisci":
        return cmd_pulisci(a.trascrizioni)
    if a.comando == "da-rileggere":
        segna_da_rileggere(a.id)
        return 0
    if a.comando == "profilo":
        p = dati.carica_profilo()
        if a.chiave not in p:
            print(f"Campo del profilo sconosciuto: {a.chiave}", file=sys.stderr)
            return 1
        v = p[a.chiave]
        print(", ".join(v) if isinstance(v, list) else v)
        return 0
    if a.comando == "prompt-note":
        testo = (BASE / "prompt-note.md").read_text(encoding="utf-8")
        print(dati.compila_prompt(testo, nome=a.titolo, data=a.data, fonte=a.fonte))
        return 0
    if a.comando == "salva-dettatura":
        salva_dettatura(a.grezzo, a.finale, a.app, a.durata)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
