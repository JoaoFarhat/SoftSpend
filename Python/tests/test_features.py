from fastapi.testclient import TestClient


def test_open_finance_desligado_por_padrao(importar_main):
    modulo = importar_main(habilitado=False)
    client = TestClient(modulo.app)

    assert client.get("/api/features").json() == {"open_finance": False}
    assert client.get("/api/open-finance/cards").status_code == 404
    assert client.post("/api/connect-token", json={}).status_code == 404
    assert client.post("/api/webhooks/pluggy", json={}).status_code == 404


def test_open_finance_ligado_expoe_rotas(importar_main):
    modulo = importar_main(habilitado=True)
    client = TestClient(modulo.app)

    assert client.get("/api/features").json() == {"open_finance": True}
    # Rotas registradas respondem auth/config, nunca 404.
    assert client.get("/api/open-finance/cards").status_code != 404
    assert client.post("/api/connect-token", json={}).status_code != 404
    assert client.post("/api/webhooks/pluggy", json={}).status_code != 404
