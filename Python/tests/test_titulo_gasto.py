"""Titulo do gasto nao pode ser so espaco ou quebra de linha.

Antes o `GastoRequest` aceitava `"   "` (o `CicloRequest` ja recusava com
`nao_somente_espacos`) e o gasto saia em branco no PDF/CSV. No app, um
titulo so com "\\n" liberava o Salvar, o envio aparava para `""` e o 422
ficava retentando com backoff para sempre. Agora o DTO tem o mesmo
validador do `CicloRequest`: devolve 422 e apara as pontas.

Mesmo padrao de `test_core_api.py`: SQLite em `tmp_path`,
`app.dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

USER_A = "user-a"


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app

    import limiter as limiter_module
    import models
    from database import Base, get_db
    from dependencies import get_current_user_id

    # Os limites por minuto tornariam a suite dependente do total de requisicoes.
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/titulo.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add(
        models.User(
            id=USER_A,
            nome="A",
            username="user_a",
            email="a@example.com",
            senha_hash="hash",
        )
    )
    session.commit()

    def override_db():
        yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_current_user_id] = lambda: USER_A
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


def _gasto_payload(**kwargs):
    payload = {
        "client_id": "gasto-client-1",
        "titulo": "Almoço",
        "valor": "25.50",
        "categoria": "ALIMENTACAO",
    }
    payload.update(kwargs)
    return payload


def _dia(client) -> dict:
    ciclo = client.post(
        "/ciclos",
        json={
            "client_id": "ciclo-client-1",
            "valor_total": "700.00",
            "periodo": "01/11/2026 a 07/11/2026",
            "diaria": "100.00",
            "titulo": "Semana de teste",
        },
    ).json()
    return client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={"client_id": "dia-client-1", "data": "2026-11-01T00:00:00Z"},
    ).json()


@pytest.mark.parametrize("titulo", ["   ", "\n", " \n "])
def test_post_gasto_com_titulo_so_espacos_da_422(client, titulo):
    dia = _dia(client)

    response = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload(titulo=titulo)
    )

    assert response.status_code == 422


@pytest.mark.parametrize("titulo", ["   ", "\n"])
def test_put_gasto_com_titulo_so_espacos_da_422(client, titulo):
    dia = _dia(client)
    gasto = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload()
    ).json()

    response = client.put(
        f"/gastos/{gasto['id']}", json=_gasto_payload(titulo=titulo)
    )

    assert response.status_code == 422


def test_post_gasto_apara_espacos_das_pontas(client):
    dia = _dia(client)

    response = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload(titulo="  Almoço  ")
    )

    assert response.status_code == 200
    assert response.json()["titulo"] == "Almoço"


def test_put_gasto_apara_espacos_das_pontas(client):
    dia = _dia(client)
    gasto = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload()
    ).json()

    response = client.put(
        f"/gastos/{gasto['id']}", json=_gasto_payload(titulo="  Jantar  ")
    )

    assert response.status_code == 200
    assert response.json()["titulo"] == "Jantar"
