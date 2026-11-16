"""Recalculo do saldo dos dias ao editar a diária do ciclo.

`PUT /ciclos/{id}` mudando a diária recalcula o `saldo` de cada dia do ciclo
(nova diária - soma dos gastos do dia); um PUT que não mexe na diária não
toca nos saldos. Sem isso o export e o app mostravam o saldo da diária velha.

Mesmo fixture `ambiente` de `test_core_api.py`: SQLite em `tmp_path` e
`dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

USER_A = "user-a"
USER_B = "user-b"


def _app(monkeypatch):
    """Reimporta `main` com env minimo, como em `test_core_api.py`."""
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
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

    engine = create_engine(f"sqlite:///{tmp_path}/editar_diaria.db")
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


def _viagem_dois_dias_um_gasto(client) -> dict:
    """Ciclo de diária 100 com dois dias e um gasto de 30 no primeiro."""
    ciclo = client.post("/ciclos", json=_ciclo_payload()).json()
    dias = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            {"client_id": "dia-1", "data": "2026-11-01T00:00:00Z"},
            {"client_id": "dia-2", "data": "2026-11-02T00:00:00Z"},
        ],
    ).json()
    gasto = client.post(
        f"/dias/{dias[0]['id']}/gastos",
        json={
            "client_id": "gasto-1",
            "titulo": "Almoço",
            "valor": "30.00",
            "categoria": "ALIMENTACAO",
        },
    )
    assert gasto.status_code == 200
    return ciclo


def _saldos_por_data(client, ciclo_id) -> list:
    corpo = client.get(f"/ciclos/{ciclo_id}").json()
    return [
        dia["saldo"]
        for dia in sorted(corpo["dias"], key=lambda d: d["data"])
    ]


def test_editar_diaria_recalcula_saldo_dos_dias(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    assert _saldos_por_data(client, ciclo["id"]) == [70.00, 100.00]

    response = client.put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(diaria="150.00")
    )

    assert response.status_code == 200
    assert response.json()["diaria"] == 150.00
    lido = client.get(f"/ciclos/{ciclo['id']}").json()
    assert _saldos_por_data(client, ciclo["id"]) == [120.00, 150.00]
    assert lido["gasto_total"] == 30.00


def test_editar_ciclo_sem_mudar_diaria_nao_mexe_nos_saldos(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)

    response = client.put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(titulo="Outro título")
    )

    assert response.status_code == 200
    assert response.json()["titulo"] == "Outro título"
    assert _saldos_por_data(client, ciclo["id"]) == [70.00, 100.00]


def test_export_csv_mostra_saldo_recalculado(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    client.put(f"/ciclos/{ciclo['id']}", json=_ciclo_payload(diaria="150.00"))

    response = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert response.status_code == 200
    texto = response.content.decode("utf-8-sig")
    assert "120.00" in texto
