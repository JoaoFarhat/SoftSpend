"""E-mail com espacos/quebras de linha em volta no cadastro e no login.

A sugestao de e-mail do teclado do iPhone costuma deixar um espaco depois do
endereco. O servidor apara o `email` de `LoginRequest` e `RegisterRequest`
antes de validar (field_validator mode="before" em dtos/auth.py), entao
entrar com " joao@exemplo.com " encontra a conta de "joao@exemplo.com".

Passa pela camada de auth real (rotas /auth/*), como test_auth_sessao.py:
SQLite em `tmp_path` e um `get_db` que faz commit/rollback como o de producao.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

SENHA = "Senha123!"


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

    engine = create_engine(f"sqlite:///{tmp_path}/email_espacos.db")
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


def _cadastrar(client, email: str, username: str = "usuario_teste"):
    return client.post(
        "/auth/register",
        json={
            "nome": "Teste",
            "username": username,
            "email": email,
            "senha": SENHA,
        },
    )


def _login(client, email: str):
    return client.post("/auth/login", json={"email": email, "senha": SENHA})


def test_login_com_espacos_em_volta_do_email_entra(client):
    resp = _cadastrar(client, "joao@exemplo.com")
    assert resp.status_code == 200, resp.text

    login = _login(client, " joao@exemplo.com ")
    assert login.status_code == 200, login.text
    assert login.json()["email"] == "joao@exemplo.com"


def test_login_com_tab_e_quebra_de_linha_entra(client):
    resp = _cadastrar(client, "joao@exemplo.com")
    assert resp.status_code == 200, resp.text

    login = _login(client, "\tjoao@exemplo.com\n")
    assert login.status_code == 200, login.text


def test_cadastro_apara_email_antes_de_gravar(client):
    resp = _cadastrar(client, " joao@exemplo.com ")
    assert resp.status_code == 200, resp.text
    assert resp.json()["email"] == "joao@exemplo.com"

    # O e-mail gravado ja sai aparado: o login sem espacos encontra a conta.
    login = _login(client, "joao@exemplo.com")
    assert login.status_code == 200, login.text


def test_cadastro_com_espacos_nao_duplica_conta(client):
    primeiro = _cadastrar(client, "joao@exemplo.com")
    assert primeiro.status_code == 200, primeiro.text

    # O mesmo e-mail com espacos em volta e o mesmo cadastro: recusa, nao duplica.
    segundo = _cadastrar(client, " joao@exemplo.com ", username="outro_username")
    assert segundo.status_code == 400
