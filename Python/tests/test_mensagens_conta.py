"""Mensagens de login e cadastro que o app mostra na tela.

O app exibe o `error` do corpo sem traduzir, então a frase sai do
servidor já em português correto: o 401 de login diz "E-mail ou senha
incorretos." (o mesmo para senha errada e e-mail inexistente, sem
revelar qual dos dois falhou) e o cadastro repetido explica que o
e-mail ou o nome de usuário já está cadastrado.

Passa pela camada de auth real (rotas /auth/*), como test_email_espacos.py:
SQLite em `tmp_path` e um `get_db` que faz commit/rollback como o de produção.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

SENHA = "Senha123!"

ERRO_LOGIN = "E-mail ou senha incorretos."
ERRO_CADASTRO_REPETIDO = "Este e-mail ou nome de usuário já está cadastrado."


def _app(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    return importlib.import_module("main").app


@pytest.fixture
def client(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module

    app = _app(monkeypatch)
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/mensagens_conta.db")
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


def _cadastrar(client, email="joao@exemplo.com", username="usuario_teste"):
    return client.post(
        "/auth/register",
        json={
            "nome": "Teste",
            "username": username,
            "email": email,
            "senha": SENHA,
        },
    )


def test_login_com_senha_errada_diz_email_ou_senha_incorretos(client):
    assert _cadastrar(client).status_code == 200

    resp = client.post(
        "/auth/login",
        json={"email": "joao@exemplo.com", "senha": "SenhaErrada1!"},
    )

    assert resp.status_code == 401, resp.text
    corpo = resp.json()
    assert corpo["error"] == ERRO_LOGIN
    assert corpo["request_id"]


def test_login_com_email_inexistente_diz_email_ou_senha_incorretos(client):
    resp = client.post(
        "/auth/login",
        json={"email": "naoexiste@exemplo.com", "senha": SENHA},
    )

    assert resp.status_code == 401, resp.text
    corpo = resp.json()
    assert corpo["error"] == ERRO_LOGIN
    assert corpo["request_id"]


def test_cadastro_com_email_repetido_explica_o_que_ja_esta_em_uso(client):
    assert _cadastrar(client).status_code == 200

    repetido = _cadastrar(client, username="outro_username")

    assert repetido.status_code == 400, repetido.text
    corpo = repetido.json()
    assert corpo["error"] == ERRO_CADASTRO_REPETIDO
    assert corpo["request_id"]


def test_titulo_do_ciclo_so_com_espacos_da_422(client):
    cadastro = _cadastrar(client)
    assert cadastro.status_code == 200, cadastro.text
    token = cadastro.json()["access_token"]

    resp = client.post(
        "/ciclos",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "client_id": "ciclo-client-1",
            "valor_total": "700.00",
            "periodo": "01/11/2026 a 07/11/2026",
            "diaria": "100.00",
            "titulo": "   ",
        },
    )

    assert resp.status_code == 422, resp.text
    assert resp.json()["campos"] == ["titulo"]
