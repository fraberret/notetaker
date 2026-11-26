import json
import subprocess
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent


def test_dentro_una_dettatura():
    from nt.diretta import dentro_dettatura
    intervalli = [(1000.0, 1005.0)]
    assert dentro_dettatura(1001.0, 1003.0, intervalli)
    assert dentro_dettatura(1004.5, 1010.0, intervalli)      # si sovrappone
    assert not dentro_dettatura(1010.0, 1012.0, intervalli)
    assert not dentro_dettatura(990.0, 998.0, intervalli)


def test_leggi_intervalli(tmp_path):
    from nt.diretta import intervalli_dettature
    (tmp_path / "dettature-in-call.jsonl").write_text('{"da": 10.5, "a": 12}\nrotta\n{"da": 20, "a": 25}\n')
    assert intervalli_dettature(tmp_path) == [(10.5, 12.0), (20.0, 25.0)]
    assert intervalli_dettature(tmp_path / "manca") == []


def test_unisci_toglie_le_dettature(tmp_path):
    d = tmp_path / "2026-11-26_10-00-00"
    d.mkdir()
    inizio = time.mktime(time.strptime(d.name, "%Y-%m-%d_%H-%M-%S"))
    (d / "inizio.json").write_text(json.dumps({"inizio_sistema": 50.0, "inizio_microfono": 50.0}))
    (d / "microfono.json").write_text(json.dumps({"transcription": [
        {"offsets": {"from": 1000, "to": 3000}, "text": " ciao a tutti"},
        {"offsets": {"from": 20000, "to": 24000}, "text": " scrivi una mail a Marco"},
        {"offsets": {"from": 40000, "to": 42000}, "text": " allora siamo d'accordo"}]}))
    (d / "sistema.json").write_text(json.dumps({"transcription": [
        {"offsets": {"from": 5000, "to": 8000}, "text": " ciao Luca"}]}))
    (d / "dettature-in-call.jsonl").write_text(json.dumps({"da": inizio + 19.5, "a": inizio + 24.5}) + "\n")
    out = d / "trascrizione.txt"
    subprocess.run([sys.executable, "-I", str(BASE / "unisci.py"), str(d), "Marco", str(out)], check=True)
    testo = out.read_text()
    assert "scrivi una mail" not in testo
    assert "ciao a tutti" in testo and "siamo d'accordo" in testo and "ciao Luca" in testo


def test_dettatura_ancora_aperta(tmp_path):
    from nt.diretta import dentro_dettatura, intervalli_dettature
    (tmp_path / "dettature-in-call.jsonl").write_text('{"da": 10}\n{"da": 10, "a": 15}\n{"da": 30}\n')
    iv = intervalli_dettature(tmp_path)
    assert (10.0, 15.0) in iv and len(iv) == 2
    assert dentro_dettatura(100.0, 102.0, iv)          # la seconda è ancora in corso
    assert not dentro_dettatura(20.0, 25.0, iv)
