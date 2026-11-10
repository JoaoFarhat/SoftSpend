"""Testes de API das rotas de ciclo, dia e gasto.

Mesmo padrao de `test_open_finance_cards_are_scoped_to_authenticated_user`
em `test_hardening.py`: SQLite em `tmp_path`, `app.dependency_overrides`
para `get_db` e `get_current_user_id` (sem passar pela camada de auth real).
"""

import importlib
import sys
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

USER_A = "user-a"
USER_B = "user-b"


def _app(monkeypatch):
    """Reimporta `main` com env minimo, como `_app_com_open_finance`.

    `services.auth_service` exige as chaves no momento do import; setar valores
    dummy deixa o arquivo auto-suficiente mesmo sem o ambiente exportado.
    """
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    return importlib.import_module("main").app


class _Ambiente:
    def __init__(self, app, session):
        self.app = app
        self.session = session

    def como(self, user_id: str, **kwargs) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app, **kwargs)


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    import models

    app = _app(monkeypatch)
    # Os limites por minuto sao testados indiretamente em test_hardening.py;
    # aqui eles tornariam a suite dependente do total de requisicoes.
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/core.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(
                id=USER_A,
                nome="A",
                username="user_a",
                email="a@example.com",
                senha_hash="hash",
            ),
            models.User(
                id=USER_B,
                nome="B",
                username="user_b",
                email="b@example.com",
                senha_hash="hash",
            ),
        ]
    )
    session.commit()

    def override_db():
        yield session

    app.dependency_overrides[get_db] = override_db
    try:
        yield _Ambiente(app, session)
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


def _ciclo_payload(**kwargs):
    payload = {
        "client_id": "ciclo-client-1",
        "valor_total": "700.00",
        "periodo": "01/11/2026 a 07/11/2026",
        "diaria": "100.00",
        "titulo": "Semana de teste",
    }
    payload.update(kwargs)
    return payload


def _dia_payload(client_id="dia-client-1", data="2026-11-01T00:00:00Z"):
    return {"client_id": client_id, "data": data}


def _gasto_payload(**kwargs):
    payload = {
        "client_id": "gasto-client-1",
        "titulo": "Almoço",
        "valor": "25.50",
        "categoria": "ALIMENTACAO",
    }
    payload.update(kwargs)
    return payload


def _criar_ciclo(client, **kwargs) -> dict:
    response = client.post("/ciclos", json=_ciclo_payload(**kwargs))
    assert response.status_code == 200
    return response.json()


def _criar_ciclo_dia_gasto(client) -> tuple[dict, dict, dict]:
    ciclo = _criar_ciclo(client)
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias", json=_dia_payload()
    ).json()
    gasto = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload()
    ).json()
    return ciclo, dia, gasto


def _duas_casas(valor) -> Decimal:
    return Decimal(str(valor)).quantize(Decimal("0.01"))


def test_criar_ciclo_dias_em_lote_gasto_e_ler_de_volta(ambiente):
    client = ambiente.como(USER_A)

    ciclo = _criar_ciclo(client)
    assert ciclo["client_id"] == "ciclo-client-1"

    response = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-1", "2026-11-01T00:00:00Z"),
            _dia_payload("dia-2", "2026-11-02T00:00:00Z"),
        ],
    )
    assert response.status_code == 200
    dias = response.json()
    assert len(dias) == 2
    assert dias[0]["saldo"] == 100.00

    gasto = client.post(
        f"/dias/{dias[0]['id']}/gastos", json=_gasto_payload()
    )
    assert gasto.status_code == 200
    assert gasto.json()["titulo"] == "Almoço"

    lido = client.get(f"/ciclos/{ciclo['id']}")
    assert lido.status_code == 200
    corpo = lido.json()
    assert corpo["gasto_total"] == 25.50
    assert len(corpo["dias"]) == 2

    dia_lido = next(d for d in corpo["dias"] if d["id"] == dias[0]["id"])
    assert dia_lido["saldo"] == 74.50
    assert len(dia_lido["gastos"]) == 1
    assert dia_lido["gastos"][0]["valor"] == 25.50

    ciclos = client.get("/usuario/ciclos")
    assert ciclos.status_code == 200
    assert [c["id"] for c in ciclos.json()] == [ciclo["id"]]


def test_reenvio_client_id_ciclo_devolve_registro_existente(ambiente):
    client = ambiente.como(USER_A)

    primeiro = _criar_ciclo(client)
    segundo = client.post("/ciclos", json=_ciclo_payload(titulo="Outro titulo"))
    assert segundo.status_code == 200
    assert segundo.json()["id"] == primeiro["id"]

    ciclos = client.get("/usuario/ciclos").json()
    assert len(ciclos) == 1


def test_reenvio_client_id_dia_devolve_registro_existente(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    primeiro = client.post(f"/ciclos/{ciclo['id']}/dias", json=_dia_payload())
    segundo = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload(data="2026-11-03T00:00:00Z"),
    )
    assert segundo.status_code == 200
    assert segundo.json()["id"] == primeiro.json()["id"]

    dias = client.get(f"/ciclos/{ciclo['id']}/dias").json()
    assert len(dias) == 1


def test_reenvio_client_id_dias_em_lote_nao_duplica(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    primeiro = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-1", "2026-11-01T00:00:00Z"),
            _dia_payload("dia-2", "2026-11-02T00:00:00Z"),
        ],
    )
    id_dia_1 = primeiro.json()[0]["id"]

    segundo = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-1", "2026-11-01T00:00:00Z"),
            _dia_payload("dia-3", "2026-11-03T00:00:00Z"),
        ],
    )
    assert segundo.status_code == 200
    assert segundo.json()[0]["id"] == id_dia_1

    dias = client.get(f"/ciclos/{ciclo['id']}/dias").json()
    assert len(dias) == 3


def test_reenvio_client_id_gasto_devolve_registro_existente(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dia, gasto = _criar_ciclo_dia_gasto(client)

    segundo = client.post(
        f"/dias/{dia['id']}/gastos",
        json=_gasto_payload(titulo="Outro titulo", valor="99.99"),
    )
    assert segundo.status_code == 200
    assert segundo.json()["id"] == gasto["id"]

    lido = client.get(f"/ciclos/{ciclo['id']}").json()
    dia_lido = lido["dias"][0]
    # O reenvio nao pode debitar saldo nem somar gasto_total duas vezes.
    assert len(dia_lido["gastos"]) == 1
    assert dia_lido["saldo"] == 74.50
    assert lido["gasto_total"] == 25.50


def test_ler_dias_de_ciclo_alheio_retorna_404(ambiente):
    ciclo, _, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.get(f"/ciclos/{ciclo['id']}/dias")

    assert response.status_code == 404


def test_ler_ciclo_alheio_retorna_404(ambiente):
    ciclo, _, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.get(f"/ciclos/{ciclo['id']}")

    assert response.status_code == 404


def test_editar_ciclo_alheio_retorna_404(ambiente):
    ciclo, _, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(titulo="Invasão")
    )

    assert response.status_code == 404
    assert client_b.get("/usuario/ciclos").json() == []
    lido_a = ambiente.como(USER_A).get(f"/ciclos/{ciclo['id']}").json()
    assert lido_a["titulo"] == "Semana de teste"


def test_exportar_ciclo_alheio_retorna_404(ambiente):
    ciclo, _, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert response.status_code == 404


def test_apagar_ciclo_alheio_retorna_404(ambiente):
    ciclo, _, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.delete(f"/ciclos/{ciclo['id']}")

    assert response.status_code == 404
    ciclos_a = ambiente.como(USER_A).get("/usuario/ciclos").json()
    assert len(ciclos_a) == 1


def test_criar_dia_em_ciclo_alheio_retorna_404(ambiente):
    ciclo, _, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.post(f"/ciclos/{ciclo['id']}/dias", json=_dia_payload("dia-b"))
    response_lote = client_b.post(
        f"/ciclos/{ciclo['id']}/dias/lote", json=[_dia_payload("dia-b")]
    )

    assert response.status_code == 404
    assert response_lote.status_code == 404
    dias_a = ambiente.como(USER_A).get(f"/ciclos/{ciclo['id']}/dias").json()
    assert len(dias_a) == 1


def test_editar_dia_alheio_retorna_404(ambiente):
    _, dia, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.put(
        f"/dias/{dia['id']}", json=_dia_payload(data="2026-11-05T00:00:00Z")
    )

    assert response.status_code == 404


def test_apagar_dia_alheio_retorna_404(ambiente):
    _, dia, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.delete(f"/dias/{dia['id']}")

    assert response.status_code == 404


def test_criar_gasto_em_dia_alheio_retorna_404(ambiente):
    _, dia, _ = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload()
    )

    assert response.status_code == 404


def test_editar_gasto_alheio_retorna_404(ambiente):
    _, _, gasto = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.put(
        f"/gastos/{gasto['id']}", json=_gasto_payload(titulo="Invasão")
    )

    assert response.status_code == 404


def test_apagar_gasto_alheio_retorna_404(ambiente):
    _, _, gasto = _criar_ciclo_dia_gasto(ambiente.como(USER_A))

    client_b = ambiente.como(USER_B)
    response = client_b.delete(f"/gastos/{gasto['id']}")

    assert response.status_code == 404


def test_apagar_ciclo_remove_dias_e_gastos(ambiente):
    import models

    client = ambiente.como(USER_A)
    ciclo, _, _ = _criar_ciclo_dia_gasto(client)

    response = client.delete(f"/ciclos/{ciclo['id']}")

    assert response.status_code == 204
    assert ambiente.session.query(models.Dia).count() == 0
    assert ambiente.session.query(models.Gasto).count() == 0
    assert client.get("/usuario/ciclos").json() == []


def test_valores_monetarios_voltam_com_duas_casas(ambiente):
    client = ambiente.como(USER_A)

    ciclo = _criar_ciclo(client, valor_total="1000.50", diaria="33.33")
    assert ciclo["valor_total"] == 1000.50
    assert _duas_casas(ciclo["valor_total"]) == Decimal("1000.50")
    assert _duas_casas(ciclo["diaria"]) == Decimal("33.33")

    dia = client.post(f"/ciclos/{ciclo['id']}/dias", json=_dia_payload()).json()
    # O validador monetario arredonda a terceira casa antes de persistir.
    gasto = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload(valor="10.456")
    ).json()
    assert _duas_casas(gasto["valor"]) == Decimal("10.46")

    lido = client.get(f"/ciclos/{ciclo['id']}").json()
    assert _duas_casas(lido["gasto_total"]) == Decimal("10.46")
    assert _duas_casas(lido["dias"][0]["saldo"]) == Decimal("22.87")


def test_exportar_csv_do_proprio_ciclo(ambiente):
    client = ambiente.como(USER_A)
    ciclo, _, _ = _criar_ciclo_dia_gasto(client)

    response = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert response.status_code == 200
    assert "text/csv" in response.headers["Content-Type"]
    texto = response.content.decode("utf-8-sig")
    assert "Semana de teste" in texto
    assert "25.50" in texto
    assert "74.50" in texto
