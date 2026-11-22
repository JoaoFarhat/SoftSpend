"""Limite por usuario: Bearer valido conta em `user:<id>`, senao no IP.

Dois usuarios no mesmo IP (CGNAT da operadora) tem cotas separadas nas
rotas com login; pedido sem token ou com token invalido/expirado cai na
cota do IP; `/auth/login` continua contado pelo IP mesmo com contas
diferentes. Mesmo molde de `test_auth_sessao.py`: SQLite em `tmp_path` e
`get_db` sobrescrito — mas aqui o `limiter` fica ligado de proposito e o
teste zera os baldes com `limiter.reset()`.
"""

import sys
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from starlette.requests import Request

import dependencies
import limiter as limiter_module

SENHA = "Senha123!"


@pytest.fixture
def client(monkeypatch, tmp_path):
    from database import Base, get_db
    from main import app

    # Deterministico: criar ciclo nao pode esbarrar no bloqueio de assinatura.
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)

    engine = create_engine(f"sqlite:///{tmp_path}/limite.db")
    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine)

    def override_db():
        db = SessionLocal()
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_db
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()
        engine.dispose()
        limiter_module.limiter.reset()


def _registrar(client, email: str, username: str) -> str:
    resp = client.post(
        "/auth/register",
        json={
            "nome": "Teste",
            "username": username,
            "email": email,
            "senha": SENHA,
        },
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["access_token"]


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


CORPO_CICLO = {
    "valor_total": "700.00",
    "periodo": "05/01 a 07/01",
    "diaria": "100.00",
    "titulo": "Viagem",
}


def _criar_ciclo(client, token: str) -> int:
    resp = client.post("/ciclos", headers=_auth(token), json=CORPO_CICLO)
    assert resp.status_code == 200, resp.text
    return resp.json()["id"]


def _post_lote(client, ciclo_id: int, token: str):
    # Mesmo client_id em todas: idempotente, so interessa a contagem do limite.
    return client.post(
        f"/ciclos/{ciclo_id}/dias/lote",
        headers=_auth(token),
        json=[{"client_id": "dia-1", "data": "2026-01-05T00:00:00Z"}],
    )


def test_dois_usuarios_no_mesmo_ip_nao_dividem_a_cota(client):
    token_a = _registrar(client, "a@example.com", "usuario_a")
    token_b = _registrar(client, "b@example.com", "usuario_b")
    limiter_module.limiter.reset()

    for _ in range(20):
        resp = client.post("/ciclos", headers=_auth(token_a), json=CORPO_CICLO)
        assert resp.status_code == 200, resp.text
    assert (
        client.post("/ciclos", headers=_auth(token_a), json=CORPO_CICLO).status_code
        == 429
    )

    # Mesmo IP ("testclient"), mas a cota do outro usuario esta intacta.
    resp = client.post("/ciclos", headers=_auth(token_b), json=CORPO_CICLO)
    assert resp.status_code == 200, resp.text


def test_dias_lote_120_passam_e_o_121_da_429(client):
    token = _registrar(client, "u@example.com", "usuario_lote")
    limiter_module.limiter.reset()
    ciclo_id = _criar_ciclo(client, token)

    for _ in range(120):
        resp = _post_lote(client, ciclo_id, token)
        assert resp.status_code == 200, resp.text
    assert _post_lote(client, ciclo_id, token).status_code == 429


def test_login_continua_contado_pelo_ip(client):
    _registrar(client, "a@example.com", "usuario_a")
    _registrar(client, "b@example.com", "usuario_b")
    limiter_module.limiter.reset()

    corpos = [
        {"email": "a@example.com", "senha": SENHA},
        {"email": "b@example.com", "senha": SENHA},
    ]
    # Contas alternadas no mesmo IP dividem o balde de 5/min do /auth/login.
    for i in range(5):
        resp = client.post("/auth/login", json=corpos[i % 2])
        assert resp.status_code == 200, resp.text
    assert client.post("/auth/login", json=corpos[0]).status_code == 429


def _request(headers: dict | None = None) -> Request:
    raw = [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()]
    return Request(
        {"type": "http", "client": ("203.0.113.9", 1234), "headers": raw}
    )


def _auth_service():
    # Mesmo modulo que `get_current_user` (e a chave do limiter) usa — outros
    # testes reimportam `services.auth_service`.
    return dependencies.auth_service


def test_chave_limite_sem_token_ou_invalido_cai_no_ip():
    auth_service = _auth_service()
    agora = datetime.now(timezone.utc)

    def _token(exp: datetime, segredo: str) -> str:
        return jwt.encode(
            {
                "sub": "user-qualquer",
                "iat": agora,
                "exp": exp,
                "iss": auth_service.JWT_ISSUER,
                "aud": auth_service.JWT_AUDIENCE,
                "type": "access",
            },
            segredo,
            algorithm=auth_service.ALGORITHM,
        )

    sem_header = _request()
    assert limiter_module.chave_limite(sem_header) == "203.0.113.9"

    assinatura_errada = _token(
        agora + timedelta(minutes=5), "chave-errada-com-pelo-menos-32-chars!"
    )
    assert (
        limiter_module.chave_limite(
            _request({"Authorization": f"Bearer {assinatura_errada}"})
        )
        == "203.0.113.9"
    )

    expirado = _token(agora - timedelta(minutes=1), auth_service.SECRET_KEY)
    assert (
        limiter_module.chave_limite(
            _request({"Authorization": f"Bearer {expirado}"})
        )
        == "203.0.113.9"
    )


def test_chave_limite_com_token_valido_vira_user_id():
    auth_service = _auth_service()
    token = auth_service.criar_access_token("user-42")

    assert (
        limiter_module.chave_limite(
            _request({"Authorization": f"Bearer {token}"})
        )
        == "user:user-42"
    )
