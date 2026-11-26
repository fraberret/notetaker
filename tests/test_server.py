import http.client
import importlib
import json
import os
import sys
import threading
import urllib.parse
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parent.parent

CALL_A = "2026-11-25 Trascrizione call Rossi"
CALL_B = "2026-11-26 Trascrizione call Dell'Orto & Co"
TESTO_A = "[00:02] Io: ciao come stai\n\n[00:05] Persona 1: bene grazie, lavoro per Querchia\n\n[01:10] Persona 2: perfetto\n"
TESTO_B = "[00:01] Io: buongiorno\n\n[00:04] Giulia: buongiorno a te\n"


@pytest.fixture
def motore(tmp_path, monkeypatch, dati_tmp):
    vault = tmp_path / "vault"
    tr = vault / "90 Fonti" / "Trascrizioni"
    tr.mkdir(parents=True)
    (vault / "00 Inbox").mkdir()
    (tr / (CALL_A + ".txt")).write_text(TESTO_A, encoding="utf-8")
    (tr / (CALL_B + ".txt")).write_text(TESTO_B, encoding="utf-8")
    (tr / (CALL_B + ".m4a")).write_bytes(bytes(range(100)))
    monkeypatch.setenv("NOTETAKER_VAULT", str(vault))
    sys.path.insert(0, str(BASE / "app"))
    import server
    importlib.reload(server)
    srv = server.crea_server()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    porta = srv.server_address[1]

    def chiama(metodo, percorso, corpo=None, gettone=True, intestazioni=None):
        c = http.client.HTTPConnection("127.0.0.1", porta, timeout=10)
        h = {"X-Gettone": server.GETTONE} if gettone else {}
        h.update(intestazioni or {})
        dati = json.dumps(corpo).encode() if corpo is not None else None
        if dati:
            h["Content-Type"] = "application/json"
        c.request(metodo, percorso, body=dati, headers=h)
        r = c.getresponse()
        b = r.read()
        try:
            return r.status, json.loads(b), r
        except Exception:
            return r.status, b, r

    yield {"chiama": chiama, "vault": vault, "tr": tr, "server": server, "tmp": tmp_path}
    srv.shutdown()
    srv.server_close()


def q(id_):
    return urllib.parse.quote(id_, safe="")


def test_senza_gettone_403(motore):
    s, _, _ = motore["chiama"]("GET", "/api/call", gettone=False)
    assert s == 403
    s, _, _ = motore["chiama"]("GET", "/audio/" + q(CALL_B), gettone=False)
    assert s == 403


def test_host_esterno_403(motore):
    s, _, _ = motore["chiama"]("GET", "/api/call", intestazioni={"Host": "evil.com"})
    assert s == 403


def test_elenco_call(motore):
    s, elenco, _ = motore["chiama"]("GET", "/api/call")
    assert s == 200
    assert [c["id"] for c in elenco] == [CALL_B, CALL_A]
    a = elenco[1]
    assert a["durata_s"] == 70 and a["data"] == "2026-11-25" and a["nome"] == "Rossi"
    assert a["persone"] == 3 and a["stato"] == "pronta"


def test_nome_con_apostrofo(motore):
    s, d, _ = motore["chiama"]("GET", "/api/call/" + q(CALL_B))
    assert s == 200 and d["nome"] == "Dell'Orto & Co" and d["audio"] is True
    s, corpo, _ = motore["chiama"]("GET", "/audio/" + q(CALL_B))
    assert s == 200 and len(corpo) == 100


def test_id_non_valido(motore):
    s, _, _ = motore["chiama"]("GET", "/api/call/" + q("../../segreto"))
    assert s == 404


def test_correzione_non_tocca_fonti(motore):
    f = motore["tr"] / (CALL_A + ".txt")
    prima = f.read_bytes()
    s, r, _ = motore["chiama"]("POST", "/api/correzioni/" + q(CALL_A), {"riga": 0, "testo": "ciao, come stai?"})
    assert s == 200
    assert f.read_bytes() == prima
    _, d, _ = motore["chiama"]("GET", "/api/call/" + q(CALL_A))
    assert d["turni"][0]["testo"] == "ciao, come stai?"
    assert d["turni"][0]["corretta"] is True


def test_correzione_propone_suggerimento(motore):
    s, r, _ = motore["chiama"]("POST", "/api/correzioni/" + q(CALL_A),
                               {"riga": 1, "testo": "bene grazie, lavoro per Bottega Quercia Srl"})
    assert ["Querchia", "Bottega Quercia Srl"] in r["suggerimenti"]


def test_nomi(motore):
    motore["chiama"]("POST", "/api/nomi/" + q(CALL_A), {"Persona 1": "Giulia"})
    _, d, _ = motore["chiama"]("GET", "/api/call/" + q(CALL_A))
    assert d["nomi"] == {"Persona 1": "Giulia"}


def test_audio_range(motore):
    s, corpo, r = motore["chiama"]("GET", "/audio/" + q(CALL_B), intestazioni={"Range": "bytes=0-9"})
    assert s == 206 and corpo == bytes(range(10))
    assert r.getheader("Content-Range") == "bytes 0-9/100"


def test_impostazioni_roundtrip(motore):
    s, imp, _ = motore["chiama"]("POST", "/api/impostazioni", {"secondi_domanda": 9, "tasto": "option_destro"})
    assert s == 200 and imp["secondi_domanda"] == 9
    _, imp, _ = motore["chiama"]("GET", "/api/impostazioni")
    assert imp["tasto"] == "option_destro" and "hammerspoon_al_login" not in imp
    salvate = json.loads((Path(os.environ["CALL_DATI"]) / "impostazioni.json").read_text())
    assert salvate["secondi_domanda"] == 9


def test_cerca_trova_dettatura_e_call(motore):
    righe = [{"t": 1764150000.5, "app": "Mail", "grezzo": "il preventivo", "testo": "Il preventivo.", "durata": 2.0}]
    (Path(os.environ["CALL_DATI"]) / "dettature.jsonl").write_text(
        "".join(json.dumps(r) + "\n" for r in righe), encoding="utf-8")
    (motore["tr"] / (CALL_A + ".txt")).write_text(TESTO_A.replace("perfetto", "perfetto il preventivo"))
    _, r, _ = motore["chiama"]("GET", "/api/cerca?q=" + q("preventivo"))
    tipi = sorted(x["tipo"] for x in r)
    assert tipi == ["call", "dettatura"]
    c = next(x for x in r if x["tipo"] == "call")
    assert c["id"] == CALL_A and c["i"] == 2


def test_dettature_modifica_ed_elimina(motore):
    p = Path(os.environ["CALL_DATI"]) / "dettature.jsonl"
    p.write_text(json.dumps({"t": 1764150000.5, "app": "Mail", "grezzo": "Querchia", "testo": "Querchia", "durata": 1}) + "\n"
                 + json.dumps({"t": 1764150100.25, "app": "Notes", "grezzo": "b", "testo": "b", "durata": 1}) + "\n")
    _, el, _ = motore["chiama"]("GET", "/api/dettature")
    assert [d["app"] for d in el] == ["Notes", "Mail"]
    _, r, _ = motore["chiama"]("POST", "/api/dettature/1764150000.5", {"testo": "Bottega Quercia Srl"})
    assert ["Querchia", "Bottega Quercia Srl"] in r["suggerimenti"]
    s, _, _ = motore["chiama"]("DELETE", "/api/dettature/1764150100.25")
    assert s == 200
    _, el, _ = motore["chiama"]("GET", "/api/dettature")
    assert len(el) == 1 and el[0]["testo"] == "Bottega Quercia Srl"


def test_dizionario_api(motore):
    c = motore["chiama"]
    c("POST", "/api/dizionario/sostituzione", {"da": "Querchia", "a": "Bottega Quercia Srl"})
    c("POST", "/api/dizionario/termine", {"testo": "Fiordaliso"})
    _, d, _ = c("GET", "/api/dizionario")
    assert d["sostituzioni"][0]["da"] == "Querchia" and d["termini"][0]["testo"] == "Fiordaliso"
    c("DELETE", "/api/dizionario/termine/Fiordaliso")
    c("DELETE", "/api/dizionario/sostituzione/Querchia")
    _, d, _ = c("GET", "/api/dizionario")
    assert d["termini"] == [] and d["sostituzioni"] == []


def test_call_in_corso(motore, tmp_path):
    reg = Path(os.environ["CALL_REGISTRAZIONI"]) / "2026-11-26_15-00-00"
    reg.mkdir(parents=True)
    (reg / "diretta.jsonl").write_text(json.dumps({"s": 3.2, "chi": "Altri", "testo": "ciao"}) + "\n"
                                       + json.dumps({"s": 7.0, "chi": "Io", "testo": "ciao a te"}) + "\n")
    Path(os.environ["CALL_STATO"]).write_text(f"{os.getpid()}\n{reg}\nAgenzia Rossi\n")
    _, elenco, _ = motore["chiama"]("GET", "/api/call")
    assert elenco[0]["id"] == "reg:2026-11-26_15-00-00" and elenco[0]["stato"] == "in_corso"
    assert elenco[0]["nome"] == "Agenzia Rossi"
    _, d, _ = motore["chiama"]("GET", "/api/call/" + q("reg:2026-11-26_15-00-00"))
    assert [t["testo"] for t in d["turni"]] == ["ciao", "ciao a te"]
    _, r, _ = motore["chiama"]("GET", "/api/diretta/" + q("reg:2026-11-26_15-00-00") + "?da=1")
    assert [x["testo"] for x in r["righe"]] == ["ciao a te"] and r["totale"] == 2


def test_da_rileggere_e_esporta(motore):
    (Path(os.environ["CALL_DATI"]) / "da-rileggere.json").write_text(json.dumps([CALL_A]))
    _, elenco, _ = motore["chiama"]("GET", "/api/call")
    assert next(c for c in elenco if c["id"] == CALL_A)["stato"] == "da_rileggere"
    motore["chiama"]("POST", "/api/nomi/" + q(CALL_A), {"Persona 1": "Giulia"})
    s, corpo, r = motore["chiama"]("POST", "/api/esporta/" + q(CALL_A))
    assert s == 200 and "attachment" in r.getheader("Content-Disposition")
    assert "Giulia: bene grazie" in corpo.decode()
