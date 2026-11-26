def test_sostituzione_parola_intera(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_sostituzione("Querchia", "Bottega Quercia Srl")
    assert d.applica("il progetto Querchia va") == "il progetto Bottega Quercia Srl va"
    assert d.applica("Querchiaki") == "Querchiaki"
    assert d.applica("QUERCHIA.") == "Bottega Quercia Srl."
    assert d.applica("xQuerchia") == "xQuerchia"


def test_sostituzione_email(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_sostituzione("bottegaquercia.esempio.it", "info@bottegaquercia.it")
    assert d.applica("scrivimi a bottegaquercia.esempio.it, grazie") == "scrivimi a info@bottegaquercia.it, grazie"
    assert d.applica("scrivimi a info.bottegaquercia.esempio.it") == "scrivimi a info.bottegaquercia.esempio.it"


def test_regola_piu_lunga_prima(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_sostituzione("Bottega", "X")
    d.aggiungi_sostituzione("Bottega Qercia", "Bottega Quercia")
    assert d.applica("Bottega Qercia") == "Bottega Quercia"
    assert d.applica("Bottega") == "X"


def test_aggiungi_sostituzione_aggiorna(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_sostituzione("Querchia", "A")
    d.aggiungi_sostituzione("querchia", "B")
    diz = d.carica()
    assert len(diz["sostituzioni"]) == 1 and diz["sostituzioni"][0]["a"] == "B"
    d.rimuovi_sostituzione("QUERCHIA")
    assert d.carica()["sostituzioni"] == []


def test_registra_usi(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_sostituzione("Querchia", "Bottega Quercia Srl")
    d.applica("Querchia e Querchia")
    assert d.carica()["sostituzioni"][0]["usi"] == 0
    d.applica("Querchia e Querchia", registra_usi=True)
    assert d.carica()["sostituzioni"][0]["usi"] == 2


def test_prompt_contiene_domanda_e_termini(dati_tmp):
    from nt import dizionario as d
    diz = {"termini": [{"testo": f"Termine{i:03d}", "usi": 1, "ultimo": 100.0 + i} for i in range(200)],
           "sostituzioni": [], "suggerimenti": []}
    diz["termini"].append({"testo": "Fiordaliso", "usi": 3, "ultimo": 1000.0})
    p = d.prompt_whisper(diz)
    assert p.startswith(d.FRASE_ESEMPIO)
    assert "?" in p
    assert "Fiordaliso" in p
    assert len(p) <= 600
    assert "Termine000" not in p  # i meno recenti restano fuori


def test_suggerimenti_da_confronto(dati_tmp):
    from nt import dizionario as d
    coppie = d.suggerimenti_da_confronto("il progetto Querchia va bene", "il progetto Bottega Quercia Srl va bene?")
    assert ("Querchia", "Bottega Quercia Srl") in coppie
    assert all("?" not in a for _, a in coppie)
    assert d.suggerimenti_da_confronto("Ciao come stai", "ciao, come stai?") == []


def test_suggerimento_approvato_diventa_regola(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_suggerimenti([("Querchia", "Bottega Quercia Srl"), ("Querchia", "Bottega Quercia Srl")], "call-1")
    assert len(d.carica()["suggerimenti"]) == 1
    d.approva_suggerimento("Querchia")
    diz = d.carica()
    assert diz["suggerimenti"] == []
    assert diz["sostituzioni"][0]["da"] == "Querchia" and diz["sostituzioni"][0]["origine"] == "suggerimento"
    # Una coppia già regola non torna tra i suggerimenti.
    d.aggiungi_suggerimenti([("Querchia", "Bottega Quercia Srl")], "call-2")
    assert d.carica()["suggerimenti"] == []
    d.aggiungi_suggerimenti([("Fiordalisa", "Fiordaliso")], "call-3")
    d.scarta_suggerimento("Fiordalisa")
    assert d.carica()["suggerimenti"] == []
    assert d.applica("Fiordalisa") == "Fiordalisa"


def test_termini(dati_tmp):
    from nt import dizionario as d
    d.aggiungi_termine("Fiordaliso")
    d.aggiungi_termine("Fiordaliso")
    diz = d.carica()
    assert len(diz["termini"]) == 1 and diz["termini"][0]["usi"] == 2
    d.rimuovi_termine("Fiordaliso")
    assert d.carica()["termini"] == []


def test_termini_dal_vault(tmp_path):
    from nt import dizionario as d
    v = tmp_path / "vault"
    for rel in ("01 Cuoio/Clienti/Mario Rossi.md", "02 Dev & AI/Clienti/Guida di stile Mario.md",
                "02 Dev & AI/Clienti/2026-11-03 Call - X.md", "90 Fonti/Clienti/Nascosto.md",
                "05 Archivio/Clienti/Vecchio.md"):
        (v / rel).parent.mkdir(parents=True, exist_ok=True)
        (v / rel).write_text("x")
    assert sorted(d.termini_dal_vault(v, ["Bottega Quercia"])) == ["Bottega Quercia", "Mario Rossi"]
    assert d.termini_dal_vault(v) == ["Mario Rossi"]
    (v / "04 Risorse/Persone").mkdir(parents=True)
    (v / "04 Risorse/Persone/Luca (fornitore).md").write_text("x")
    assert "Luca" in d.termini_dal_vault(v)


def test_suggerimenti_ignorano_solo_accenti(dati_tmp):
    from nt import dizionario as d
    assert d.suggerimenti_da_confronto("si tutto bene perche no", "Sì, tutto bene, perché no.") == []


def test_suggerimenti_senza_numeri(dati_tmp):
    from nt import dizionario as d
    assert d.suggerimenti_da_confronto("costa 2000 euro", "costa 2.000 euro") == []
    assert d.suggerimenti_da_confronto("costa duemila euro", "costa 2.000 euro") == [("duemila", "2.000")]
