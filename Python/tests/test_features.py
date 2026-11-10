import importlib
import sys

from fastapi.testclient import TestClient


def _importar_main(monkeypatch, habilitado: bool):
    if habilitado:
        monkeypatch.setenv("OPEN_FINANCE_ENABLED", "true")
    else:
        monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    return importlib.import_module("main")


def test_open_finance_desligado_por_padrao(monkeypatch):
    modulo = _importar_main(monkeypatch, habilitado=False)
    client = TestClient(modulo.app)

    assert client.get("/api/features").json() == {"open_finance": False}
    assert client.get("/api/open-finance/cards").status_code == 404
    assert client.post("/api/connect-token", json={}).status_code == 404
    assert client.post("/api/webhooks/pluggy", json={}).status_code == 404


def test_open_finance_ligado_expoe_rotas(monkeypatch):
    modulo = _importar_main(monkeypatch, habilitado=True)
    client = TestClient(modulo.app)

    assert client.get("/api/features").json() == {"open_finance": True}
    # Rotas registradas respondem auth/config, nunca 404.
    assert client.get("/api/open-finance/cards").status_code != 404
    assert client.post("/api/connect-token", json={}).status_code != 404
    assert client.post("/api/webhooks/pluggy", json={}).status_code != 404
