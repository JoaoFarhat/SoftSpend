"""Webhook da Apple: `IntegrityError` no commit que não é aviso repetido.

`processar_notificacao` só pode tratar o conflito como "repetida" quando o
`notification_uuid` de fato já está gravado (reenvio simultâneo do mesmo
aviso). Um conflito em outra linha — ex.: o único de
`assinaturas.original_transaction_id` quando um `POST
/api/assinatura/transacoes` liga a mesma compra a outra conta no mesmo
instante — relança o erro: a rota responde 500 e a Apple reenvia, senão a
renovação, o reembolso ou o cancelamento daquele aviso sumiria em silêncio.

Montagem e `FakeApple` no molde de `tests/test_assinatura_as2.py`: nenhum
teste chama a Apple nem usa certificado real.
"""

import importlib
import logging
import sys
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

import models
from services import apple_service
from services.apple_service import (
    AmbienteErrado,
    AppleIndisponivel,
    ComprovanteInvalido,
    EstadoApple,
    Notificacao,
    Transacao,
)

USER_A = "user-a"
BUNDLE = "br.com.softspend.app"
MENSAL = "br.com.softspend.app.assinatura.mensal"
TIPO = "Auto-Renewable Subscription"


def _agora_real():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _tx(**campos) -> Transacao:
    base = dict(
        original_transaction_id="otid-1",
        transaction_id="t-1",
        bundle_id=BUNDLE,
        produto=MENSAL,
        tipo=TIPO,
        app_account_token=None,
        expira_em=_agora_real() + timedelta(days=30),
        ambiente="Production",
    )
    base.update(campos)
    return Transacao(**base)


# ------------------------------------------------------------------ fakes


class FakeApple:
    def __init__(self):
        self.transacoes: dict[str, tuple[Transacao, str]] = {}
        self.notificacoes: dict[str, tuple[Notificacao, str]] = {}
        self.estados: dict[tuple[str, str], EstadoApple] = {}
        self.fora_do_ar = False
        self.falhar: set[str] = set()
        self.consultas: list[tuple[str, str]] = []

    def jws(self, nome: str, transacao: Transacao, ambiente: str = "Production") -> str:
        self.transacoes[nome] = (transacao, ambiente)
        return nome

    def payload(self, nome: str, notificacao: Notificacao, ambiente: str = "Production") -> str:
        self.notificacoes[nome] = (notificacao, ambiente)
        return nome

    def estado(self, transacao: Transacao, status: int | None, renovacao=None, ambiente="Production"):
        self.estados[(ambiente, transacao.original_transaction_id)] = EstadoApple(
            status=status, transacao=transacao, renovacao=renovacao
        )

    def verificador(self, ambiente):
        return _FakeVerificador(self, ambiente)

    def cliente(self, ambiente):
        return _FakeCliente(self, ambiente)


class _FakeVerificador:
    def __init__(self, fake, ambiente):
        self.fake, self.ambiente = fake, ambiente

    def _achar(self, tabela, chave):
        if chave not in tabela:
            raise ComprovanteInvalido("assinatura inválida")
        valor, ambiente = tabela[chave]
        if ambiente != self.ambiente:
            raise AmbienteErrado("outro ambiente")
        return valor

    def verificar_transacao(self, jws):
        return self._achar(self.fake.transacoes, jws)

    def verificar_notificacao(self, payload):
        return self._achar(self.fake.notificacoes, payload)


class _FakeCliente:
    def __init__(self, fake, ambiente):
        self.fake, self.ambiente = fake, ambiente

    def status(self, original_transaction_id):
        self.fake.consultas.append((self.ambiente, original_transaction_id))
        if self.fake.fora_do_ar:
            raise AppleIndisponivel("fora do ar")
        if original_transaction_id in self.fake.falhar:
            raise RuntimeError("erro da Apple")
        return self.fake.estados.get((self.ambiente, original_transaction_id))


# --------------------------------------------------------------- ambiente


class _Ambiente:
    def __init__(self, app, session, fake):
        self.app, self.session, self.fake = app, session, fake

    def como(self, user_id: str) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app)

    def token(self, user_id: str) -> str:
        return self.como(user_id).get("/api/assinatura").json()["app_account_token"]

    def linha(self, user_id: str):
        self.session.expire_all()
        return self.session.query(models.Assinatura).filter_by(user_id=user_id).first()

    def notificacoes(self):
        return self.session.query(models.AppleNotificacao).all()


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module

    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv("REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!")
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    monkeypatch.delenv("APPLE_ACEITA_SANDBOX", raising=False)
    monkeypatch.setenv("APPLE_BUNDLE_ID", BUNDLE)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    fake = FakeApple()
    monkeypatch.setattr(apple_service, "obter_verificador", fake.verificador)
    monkeypatch.setattr(apple_service, "obter_cliente_apple", fake.cliente)

    engine = create_engine(f"sqlite:///{tmp_path}/conflito.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add(
        models.User(id=USER_A, nome="A", username="a", email="a@e.com", senha_hash="h")
    )
    session.commit()

    def override_db():
        yield session
        session.commit()

    app.dependency_overrides[get_db] = override_db
    try:
        yield _Ambiente(app, session, fake)
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


# ----------------------------------------------------------------- webhook


def _notif(uuid="n-1", tipo="DID_RENEW", subtipo=None, transacao=None, assinada_em=None,
           status=None, renovacao=None):
    return Notificacao(
        uuid=uuid, tipo=tipo, subtipo=subtipo, assinada_em=assinada_em or _agora_real(),
        status=status, transacao=transacao, renovacao=renovacao,
    )


def _webhook(amb, payload):
    return TestClient(amb.app).post("/api/webhooks/apple", json={"signedPayload": payload})


def _ligar(amb, user_id=USER_A, status=1, **campos):
    """Liga uma compra ao usuário por /transacoes e devolve a transação."""
    token = amb.token(user_id)
    tx = _tx(app_account_token=token, **campos)
    jws = amb.fake.jws(f"jws-{user_id}", tx)
    amb.fake.estado(tx, status)
    assert amb.como(user_id).post("/api/assinatura/transacoes", json={"jws": jws}).status_code == 200
    amb.fake.consultas.clear()
    return tx


def _commit_falha_uma_vez(session, monkeypatch, antes=None):
    """O `commit` da sessão roda `antes()` e lança `IntegrityError` uma vez.

    Simula a corrida: outra requisição grava no intervalo entre o SELECT da
    notificação e o commit desta. As chamadas seguintes voltam ao commit de
    verdade, como se a corrida tivesse passado.
    """
    commit_real = session.commit
    chamadas = []

    def commit_quebrado():
        if chamadas:
            return commit_real()
        chamadas.append(1)
        if antes is not None:
            antes()
        raise IntegrityError("INSERT ...", {}, Exception("conflito de unicidade"))

    monkeypatch.setattr(session, "commit", commit_quebrado)


def test_integrity_error_sem_o_aviso_gravado_500_e_apple_repete(ambiente, monkeypatch, caplog):
    """O conflito não é o `notification_uuid` (ex.: o único de
    `assinaturas.original_transaction_id`): 500, e o reenvio da Apple é
    processado de verdade — não some como "repetida"."""
    tx = _ligar(ambiente)
    ambiente.fake.estado(_tx(expira_em=_agora_real() - timedelta(days=1)), 2)
    payload = ambiente.fake.payload(
        "p-1", _notif(tipo="EXPIRED", subtipo="VOLUNTARY", transacao=tx)
    )
    _commit_falha_uma_vez(ambiente.session, monkeypatch)

    with caplog.at_level(logging.ERROR, logger="services.assinatura_service"):
        assert _webhook(ambiente, payload).status_code == 500
    assert ambiente.notificacoes() == []
    assert ambiente.linha(USER_A).status == "active"

    # O erro é logado só com o tipo: sem uuid, transação nem token.
    [erro] = [r for r in caplog.records if r.name == "services.assinatura_service"]
    mensagem = erro.getMessage()
    assert "EXPIRED" in mensagem
    for vazado in ("n-1", "otid-1", ambiente.linha(USER_A).app_account_token):
        assert vazado not in mensagem

    # A Apple repete o mesmo aviso: o commit funciona e reconcilia.
    assert _webhook(ambiente, payload).status_code == 200
    assert ambiente.linha(USER_A).status == "expired"
    [registro] = ambiente.notificacoes()
    assert registro.notification_uuid == "n-1"


def test_integrity_error_com_o_aviso_gravado_por_outra_sessao_200(ambiente, monkeypatch):
    """O mesmo `notification_uuid` foi gravado por outra requisição entre o
    SELECT e o commit: é reenvio de verdade — 200, sem reprocessar."""
    tx = _ligar(ambiente)
    ambiente.fake.estado(_tx(expira_em=_agora_real() - timedelta(days=1)), 2)
    payload = ambiente.fake.payload(
        "p-1", _notif(tipo="EXPIRED", subtipo="VOLUNTARY", transacao=tx)
    )

    def outra_sessao_grava():
        outra = Session(ambiente.session.get_bind())
        try:
            outra.add(
                models.AppleNotificacao(
                    notification_uuid="n-1",
                    tipo="EXPIRED",
                    subtipo="VOLUNTARY",
                    original_transaction_id="otid-1",
                    recebida_em=_agora_real(),
                )
            )
            outra.commit()
        finally:
            outra.close()

    _commit_falha_uma_vez(ambiente.session, monkeypatch, antes=outra_sessao_grava)

    assert _webhook(ambiente, payload).status_code == 200
    # Só a linha gravada pela outra sessão fica; nada desta foi aplicado.
    [registro] = ambiente.notificacoes()
    assert registro.notification_uuid == "n-1"
    assert ambiente.linha(USER_A).status == "active"
