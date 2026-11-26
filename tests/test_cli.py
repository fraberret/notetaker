import json


def test_salva_dettatura(dati_tmp):
    from nt import cli
    assert cli.main(["salva-dettatura", "--grezzo", "il progetto querchia", "--finale", "Il progetto Bottega Quercia Srl",
                     "--app", "Mail", "--durata", "2.5"]) == 0
    assert cli.main(["salva-dettatura", "--grezzo", "ciao", "--finale", "Ciao", "--app", "Note di Dell'Orto",
                     "--durata", "1"]) == 0
    righe = [json.loads(r) for r in (dati_tmp / "dettature.jsonl").read_text(encoding="utf-8").splitlines()]
    assert len(righe) == 2
    assert set(righe[0]) == {"t", "app", "grezzo", "testo", "durata"}
    assert righe[0]["testo"] == "Il progetto Bottega Quercia Srl" and righe[0]["durata"] == 2.5
    assert righe[1]["app"] == "Note di Dell'Orto" and righe[1]["t"] >= righe[0]["t"]


def test_impostazione(dati_tmp, capsys):
    from nt import cli
    assert cli.main(["impostazione", "tasto"]) == 0
    assert capsys.readouterr().out.strip() == "fn"


def test_profilo_e_prompt_note(dati_tmp, capsys):
    from nt import cli, dati
    (dati.CARTELLA_DATI / "profilo.json").write_text(json.dumps({"nome": "Anna", "descrizione": "grafica, Torino",
                                                                 "vault": "/tmp/vault-anna"}))
    assert cli.main(["profilo", "vault"]) == 0
    assert capsys.readouterr().out.strip() == "/tmp/vault-anna"
    assert cli.main(["prompt-note", "Studio Bianchi", "2026-11-26", "2026-11-26 Trascrizione call Studio Bianchi.txt"]) == 0
    p = capsys.readouterr().out
    assert "per Anna (grafica, Torino)" in p and '"Io" è sempre Anna' in p
    assert "# Note call Studio Bianchi (2026-11-26)" in p and "[[2026-11-26 Trascrizione call Studio Bianchi.txt]]" in p
    assert "{{" not in p
