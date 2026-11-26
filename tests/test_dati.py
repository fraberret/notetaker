import json


def test_impostazioni_predefinite(dati_tmp):
    from nt import dati
    imp = dati.carica_impostazioni()
    assert imp["giorni_audio"] == 90
    assert imp["tasto"] == "fn"
    assert imp["secondi_domanda"] == 6
    assert imp["giorni_dettature"] == 0


def test_salva_e_ricarica(dati_tmp):
    from nt import dati
    dati.salva_impostazioni({"suoni": False})
    imp = dati.carica_impostazioni()
    assert imp["suoni"] is False
    assert imp["volume"] == 0.45


def test_tipo_sbagliato_torna_predefinito(dati_tmp):
    from nt import dati
    (dati.CARTELLA_DATI / "impostazioni.json").write_text(json.dumps({"secondi_domanda": "tanti", "sconosciuta": 1}))
    imp = dati.carica_impostazioni()
    assert imp["secondi_domanda"] == 6
    assert "sconosciuta" not in imp


def test_tasto_non_valido_torna_predefinito(dati_tmp):
    from nt import dati
    assert dati.salva_impostazioni({"tasto": "ctrl"})["tasto"] == "fn"
    assert dati.salva_impostazioni({"tasto": "option_destro"})["tasto"] == "option_destro"


def test_scrittura_atomica(dati_tmp):
    from nt import dati
    p = dati.CARTELLA_DATI / "prova.json"
    dati.scrivi_json(p, {"a": 1})
    assert dati.leggi_json(p, None) == {"a": 1}
    assert not list(dati.CARTELLA_DATI.glob("*.tmp"))


def test_profilo_predefinito(dati_tmp):
    from nt import dati
    p = dati.carica_profilo()
    assert p["nome"] == "l'utente" and p["descrizione"] == "" and p["termini_fissi"] == []
    assert p["vault"].endswith("Vault")


def test_profilo_dal_file(dati_tmp):
    from nt import dati
    (dati.CARTELLA_DATI / "profilo.json").write_text(json.dumps(
        {"nome": "Anna", "descrizione": "grafica, Torino", "vault": "~/Documenti/Note", "termini_fissi": ["Studio Anna"],
         "altro": 1}))
    p = dati.carica_profilo()
    assert p["nome"] == "Anna" and p["termini_fissi"] == ["Studio Anna"] and "altro" not in p
    assert not p["vault"].startswith("~")
