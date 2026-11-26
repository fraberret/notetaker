import importlib
import sys
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parent.parent
if str(BASE) not in sys.path:
    sys.path.insert(0, str(BASE))


@pytest.fixture
def dati_tmp(tmp_path, monkeypatch):
    """CALL_DATI (e registrazioni/stato) verso cartelle temporanee, moduli nt ricaricati."""
    cartella = tmp_path / "dati"
    monkeypatch.setenv("CALL_DATI", str(cartella))
    monkeypatch.setenv("CALL_REGISTRAZIONI", str(tmp_path / "registrazioni"))
    monkeypatch.setenv("CALL_STATO", str(tmp_path / "stato"))
    import nt.dati
    importlib.reload(nt.dati)
    for nome in ("nt.dizionario", "nt.rilettura", "nt.cli"):
        if nome in sys.modules:
            importlib.reload(sys.modules[nome])
    return cartella
