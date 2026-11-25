"""O log JSON grava os campos de cada pedido, sem gravar o valor enviado.

`JSONFormatter.format` so copiava `record.extra`, atributo que o logging
nunca cria: o `extra={...}` do `logger.info` vira atributo direto do
`LogRecord`. Por isso nenhum log trazia `method`, `path`, `status_code`,
`duration_ms`, `ip` nem `errors`. Agora o formatter copia todo atributo fora
da lista dos atributos padrao — e o handler de validacao loga so `loc` e
`type` de cada erro, porque o `input` traria o valor digitado (ate a senha).

Mesmo padrao de test_email_espacos.py: SQLite em `tmp_path`, `get_db` com
commit/rollback como o de producao e `limiter.enabled = False`.
"""

import importlib
import json
import logging
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from logging_config import JSONFormatter


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

    engine = create_engine(f"sqlite:///{tmp_path}/logging_config.db")
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


def _json_do_record(record):
    return json.loads(JSONFormatter().format(record))


def test_extra_vai_para_o_json(caplog):
    logger = logging.getLogger("teste_logging_extra")
    with caplog.at_level(logging.INFO, logger="teste_logging_extra"):
        logger.info("x", extra={"path": "/a", "status_code": 200})

    dados = _json_do_record(caplog.records[-1])
    assert dados["path"] == "/a"
    assert dados["status_code"] == 200


def test_extra_nao_sobrescreve_message_nem_level():
    # `message` e `asctime` nao podem ir pelo `extra` do logger.info (o
    # logging recusa), entao o record e montado na mao: atributo nao-padrao
    # nenhum pode trocar os campos fixos do log.
    record = logging.makeLogRecord(
        {
            "name": "teste_logging_extra",
            "msg": "mensagem original",
            "levelno": logging.INFO,
            "levelname": "INFO",
            "message": "falsa",
            "level": "CRITICAL",
        }
    )

    dados = _json_do_record(record)
    assert dados["message"] == "mensagem original"
    assert dados["level"] == "INFO"


def test_erro_de_validacao_nao_grava_o_valor_enviado(client, caplog):
    with caplog.at_level(logging.INFO):
        resposta = client.post(
            "/auth/register",
            json={
                "nome": "Teste",
                "username": "joao_teste",
                "email": "joao@",
                "senha": "Segredo#123",
            },
        )

    assert resposta.status_code == 422
    for record in caplog.records:
        texto = JSONFormatter().format(record)
        assert "Segredo#123" not in texto
        assert "joao@" not in texto

    validacao = next(
        _json_do_record(record)
        for record in caplog.records
        if record.getMessage() == "Validation error"
    )
    assert validacao["errors"][0]["loc"] == ["body", "email"]
    assert validacao["errors"][0]["type"]


def test_request_finished_traz_status_code_e_duration_ms(client, caplog):
    with caplog.at_level(logging.INFO):
        resposta = client.get("/health")

    assert resposta.status_code == 200
    terminados = [
        _json_do_record(record)
        for record in caplog.records
        if record.getMessage() == "Request finished"
    ]
    assert terminados
    assert terminados[-1]["status_code"] == 200
    assert terminados[-1]["duration_ms"] >= 0
