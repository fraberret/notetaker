import json
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent


def test_eco_con_inizio_anticipato(tmp_path):
    """Whisper col filtro dei silenzi può far iniziare il pezzo del microfono molto prima della frase."""
    d = tmp_path / "2026-11-26_10-00-00"
    d.mkdir()
    (d / "inizio.json").write_text(json.dumps({"inizio_sistema": 50.0, "inizio_microfono": 50.3}))
    (d / "microfono.json").write_text(json.dumps({"transcription": [
        {"offsets": {"from": 870, "to": 11290}, "text": " Buongiorno a tutti, iniziamo la riunione sul nuovo sito."},
        {"offsets": {"from": 30000, "to": 32000}, "text": " Sì, va bene."}]}))
    (d / "sistema.json").write_text(json.dumps({"transcription": [
        {"offsets": {"from": 8230, "to": 11570}, "text": " Buongiorno a tutti, iniziamo la riunione sul nuovo sito."}]}))
    out = d / "t.txt"
    subprocess.run([sys.executable, "-I", str(BASE / "unisci.py"), str(d), "Marco", str(out)], check=True)
    testo = out.read_text()
    assert testo.count("Buongiorno") == 1 and "Marco: Buongiorno" in testo
    assert "Io: Sì, va bene." in testo


def test_eco_parziale(tmp_path):
    """Il microfono riprende solo un pezzo della frase detta dalle casse: è sempre eco."""
    d = tmp_path / "2026-11-26_10-00-00"
    d.mkdir()
    (d / "inizio.json").write_text(json.dumps({"inizio_sistema": 50.0, "inizio_microfono": 50.0}))
    (d / "microfono.json").write_text(json.dumps({"transcription": [
        {"offsets": {"from": 9000, "to": 11000}, "text": " Possiamo partire dal nuovo sito."},
        {"offsets": {"from": 30000, "to": 32000}, "text": " Il sito, certo."}]}))
    (d / "sistema.json").write_text(json.dumps({"transcription": [
        {"offsets": {"from": 6000, "to": 11500},
         "text": " Buongiorno a tutti, sono Giulia dello Studio Rossi. Possiamo partire dal nuovo sito."}]}))
    out = d / "t.txt"
    subprocess.run([sys.executable, "-I", str(BASE / "unisci.py"), str(d), "Giulia", str(out)], check=True)
    testo = out.read_text()
    assert "Io: Possiamo" not in testo
    assert "Io: Il sito, certo." in testo
