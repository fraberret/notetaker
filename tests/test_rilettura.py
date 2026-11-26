import re
from pathlib import Path

FINTO = str(Path(__file__).resolve().parent / "finto_claude.sh")


def righe_finte(n):
    return [f"[{i // 60:02d}:{i % 60:02d}] {'Io' if i % 2 else 'Persona 1'}: frase numero {i}" for i in range(n)]


def dentro(richiesta):
    return re.search(r"<trascrizione>\n(.*)\n</trascrizione>", richiesta, re.S).group(1)


def test_pezzi_lunghi():
    from nt.rilettura import pezzi
    righe = righe_finte(650)
    p = pezzi(righe)
    assert len(p) == 6
    assert [r for x in p for r in x] == righe


def test_valida_rifiuta_righe_perse():
    from nt.rilettura import valida
    r = righe_finte(5)
    assert valida(r, list(r))
    assert not valida(r, r[:4])


def test_valida_rifiuta_persona_cambiata():
    from nt.rilettura import valida
    r = righe_finte(3)
    altra = list(r)
    altra[0] = altra[0].replace("Persona 1", "Persona 2")
    assert not valida(r, altra)
    orario = list(r)
    orario[1] = orario[1].replace("[00:01]", "[00:02]")
    assert not valida(r, orario)


def test_rileggi_con_finto_claude(dati_tmp):
    from nt import dizionario
    from nt.rilettura import rileggi
    dizionario.aggiungi_sostituzione("Querchia", "Bottega Quercia Srl")
    testo = "[00:01] Persona 1: ciao come stai\n\n[00:04] Io: bene, lavoro per Querchia\n"

    def finto(richiesta):
        assert "Querchia → Bottega Quercia Srl" in richiesta  # il dizionario arriva a Claude
        return dentro(richiesta).replace("come stai", "come stai?")

    out = rileggi(testo, esegui=finto)
    assert "come stai?" in out
    assert "Bottega Quercia Srl" in out
    assert out.count("\n\n") == 1


def test_rileggi_call_lunga_a_pezzi(dati_tmp):
    from nt.rilettura import rileggi
    righe = righe_finte(650)
    chiamate = []

    def finto(richiesta):
        chiamate.append(1)
        return dentro(richiesta)

    out = rileggi("\n\n".join(righe) + "\n", esegui=finto)
    assert len(chiamate) == 6
    assert out.strip().split("\n\n") == righe


def test_rileggi_fallisce_se_claude_non_risponde(dati_tmp):
    from nt.rilettura import rileggi
    assert rileggi("[00:01] Io: ciao\n", esegui=lambda r: None) is None


def test_rileggi_fallisce_se_righe_cambiano(dati_tmp):
    from nt.rilettura import rileggi
    testo = "[00:01] Io: ciao\n\n[00:03] Persona 1: ciao a te\n"
    assert rileggi(testo, esegui=lambda r: dentro(r).split("\n\n")[0]) is None


def test_esegui_claude_con_variabile(monkeypatch):
    from nt.rilettura import esegui_claude
    monkeypatch.setenv("CALL_CLAUDE", FINTO)
    assert esegui_claude("ciao, prova") == "ciao, prova"
    monkeypatch.setenv("CALL_CLAUDE", "/usr/bin/false")
    assert esegui_claude("ciao") is None
