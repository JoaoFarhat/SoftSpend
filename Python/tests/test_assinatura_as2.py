"""Assinatura AS2 (`docs/assinatura.md` §2.8): Apple no servidor.

Nenhum teste chama a Apple nem usa certificado real: `obter_verificador` e
`obter_cliente_apple` são trocados por `FakeApple`, que conhece JWS "falsos"
(strings) e o estado que a App Store Server API devolveria.
"""

import importlib
import sys
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from services import apple_service, assinatura_job, assinatura_service
from services.apple_service import (
    AmbienteErrado,
    AppleIndisponivel,
    ComprovanteInvalido,
    EstadoApple,
    Notificacao,
    Renovacao,
    Transacao,
)

USER_A = "user-a"
USER_B = "user-b"
BUNDLE = "br.com.softspend.app"
MENSAL = "br.com.softspend.app.assinatura.mensal"
ANUAL = "br.com.softspend.app.assinatura.anual"
TIPO = "Auto-Renewable Subscription"
AGORA = datetime(2026, 11, 13, 12, 0, 0)
UM_SEG = timedelta(seconds=1)


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

    # Registro de dados de teste
    def jws(self, nome: str, transacao: Transacao, ambiente: str = "Production") -> str:
        self.transacoes[nome] = (transacao, ambiente)
        return nome

    def payload(self, nome: str, notificacao: Notificacao, ambiente: str = "Production") -> str:
        self.notificacoes[nome] = (notificacao, ambiente)
        return nome

    def estado(self, transacao: Transacao, status: int, renovacao=None, ambiente="Production"):
        self.estados[(ambiente, transacao.original_transaction_id)] = EstadoApple(
            status=status, transacao=transacao, renovacao=renovacao
        )

    # Fábricas (substituem as de `apple_service`)
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
        import models

        self.session.expire_all()
        return self.session.query(models.Assinatura).filter_by(user_id=user_id).first()

    def notificacoes(self):
        import models

        return self.session.query(models.AppleNotificacao).all()


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    import models

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

    engine = create_engine(f"sqlite:///{tmp_path}/as2.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(id=USER_A, nome="A", username="a", email="a@e.com", senha_hash="h"),
            models.User(id=USER_B, nome="B", username="b", email="b@e.com", senha_hash="h"),
        ]
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


# ======================================================== 1. reconciliar


def _ren(**campos) -> Renovacao:
    return Renovacao(**campos)


EXP_FUT = AGORA + timedelta(days=30)
EXP_PAS = AGORA - timedelta(days=1)
TRIAL_TX = dict(offer_type=1, offer_discount_type="FREE_TRIAL", expira_em=AGORA + timedelta(days=14))

# (caso §2.4, status da API, campos da transação, renovação, estado gravado, acesso)
TABELA_24 = [
    ("SUBSCRIBED/INITIAL_BUY com teste grátis", 1, TRIAL_TX, _ren(renovacao_automatica=True), "trial", True),
    ("SUBSCRIBED/INITIAL_BUY sem teste grátis", 1, dict(expira_em=EXP_FUT), _ren(renovacao_automatica=True), "active", True),
    ("SUBSCRIBED/INITIAL_BUY com desconto pago (não é trial)", 1,
     dict(offer_type=1, offer_discount_type="PAY_AS_YOU_GO", expira_em=EXP_FUT), None, "active", True),
    ("SUBSCRIBED/RESUBSCRIBE", 1, dict(expira_em=EXP_FUT), None, "active", True),
    ("DID_RENEW", 1, dict(expira_em=EXP_FUT), None, "active", True),
    ("DID_RENEW/BILLING_RECOVERY", 1, dict(expira_em=EXP_FUT), None, "active", True),
    ("DID_CHANGE_RENEWAL_STATUS/AUTO_RENEW_DISABLED", 1, dict(expira_em=EXP_FUT),
     _ren(renovacao_automatica=False), "active", True),
    ("DID_CHANGE_RENEWAL_STATUS/AUTO_RENEW_ENABLED", 1, TRIAL_TX, _ren(renovacao_automatica=True), "trial", True),
    ("DID_CHANGE_RENEWAL_PREF/UPGRADE", 1, dict(produto=ANUAL, expira_em=EXP_FUT), None, "active", True),
    ("DID_FAIL_TO_RENEW/GRACE_PERIOD", 4, dict(expira_em=EXP_PAS),
     _ren(carencia_ate=AGORA + timedelta(days=15), em_nova_tentativa=True), "grace", True),
    ("DID_FAIL_TO_RENEW", 3, dict(expira_em=EXP_PAS), _ren(em_nova_tentativa=True), "billing_retry", False),
    ("GRACE_PERIOD_EXPIRED", 3, dict(expira_em=AGORA - timedelta(days=16)),
     _ren(carencia_ate=EXP_PAS, em_nova_tentativa=True), "billing_retry", False),
    ("EXPIRED/VOLUNTARY", 2, dict(expira_em=EXP_PAS), None, "expired", False),
    ("EXPIRED/BILLING_RETRY", 2, dict(expira_em=EXP_PAS), None, "expired", False),
    ("EXPIRED/PRICE_INCREASE", 2, dict(expira_em=EXP_PAS), None, "expired", False),
    ("EXPIRED/PRODUCT_NOT_FOR_SALE", 2, dict(expira_em=EXP_PAS), None, "expired", False),
    ("REFUND", 5, dict(expira_em=EXP_FUT, revogada_em=AGORA), None, "revoked", False),
    ("REVOKE", 5, dict(expira_em=EXP_FUT, revogada_em=AGORA), None, "revoked", False),
    ("REFUND_REVERSED (volta ao estado da API)", 1, dict(expira_em=EXP_FUT), None, "active", True),
    ("OFFER_REDEEMED", 1, dict(expira_em=EXP_FUT), None, "active", True),
    ("RENEWAL_EXTENDED", 1, dict(expira_em=AGORA + timedelta(days=40)), None, "active", True),
    ("RENEWAL_EXTENSION", 1, dict(expira_em=AGORA + timedelta(days=40)), None, "active", True),
]


def _linha_vazia():
    return SimpleNamespace(
        original_transaction_id=None, produto=None, ambiente=None, status="none",
        expira_em=None, carencia_ate=None, renovacao_automatica=None, atualizado_em=None,
    )


class _DbFalso:
    def add(self, _):
        pass


@pytest.mark.parametrize(
    "status_apple, campos, renovacao, esperado, acesso",
    [caso[1:] for caso in TABELA_24],
    ids=[caso[0] for caso in TABELA_24],
)
def test_reconciliar_tabela_24(status_apple, campos, renovacao, esperado, acesso):
    linha = _linha_vazia()
    tx = _tx(**campos)
    assinatura_service.reconciliar(
        _DbFalso(), linha, tx, renovacao, AGORA, status_apple=status_apple, ambiente="Sandbox"
    )
    assert linha.status == esperado
    assert assinatura_service.calcular_acesso(linha, AGORA) == (esperado, acesso)
    assert linha.original_transaction_id == "otid-1"
    assert linha.produto == tx.produto
    assert linha.ambiente == "Sandbox"
    assert linha.expira_em == tx.expira_em
    assert linha.atualizado_em == AGORA
    if renovacao is not None and renovacao.renovacao_automatica is not None:
        assert linha.renovacao_automatica is renovacao.renovacao_automatica
    if esperado == "grace":
        assert linha.carencia_ate == renovacao.carencia_ate


def test_tabela_24_cobre_todos_os_estados_com_compra():
    assert {caso[4] for caso in TABELA_24} == set(assinatura_service.ESTADOS) - {"none"}


def test_reconciliar_status_desconhecido_falha():
    with pytest.raises(ValueError):
        assinatura_service.traduzir_status(9, _tx(), None, AGORA)


@pytest.mark.parametrize(
    "caso, campos, renovacao, esperado",
    [
        ("vence no mesmo segundo", dict(expira_em=AGORA), None, "expired"),
        ("um segundo antes do vencimento", dict(expira_em=AGORA + UM_SEG), None, "active"),
        ("trial no último segundo", dict(TRIAL_TX, expira_em=AGORA + UM_SEG), None, "trial"),
        ("vencido, na carência", dict(expira_em=EXP_PAS), _ren(carencia_ate=AGORA + UM_SEG), "grace"),
        ("carência vence no mesmo segundo", dict(expira_em=EXP_PAS),
         _ren(carencia_ate=AGORA, em_nova_tentativa=True), "billing_retry"),
        ("carência vencida, sem nova tentativa", dict(expira_em=EXP_PAS), _ren(carencia_ate=EXP_PAS), "expired"),
        ("revogada", dict(expira_em=EXP_FUT, revogada_em=EXP_PAS), None, "revoked"),
    ],
)
def test_reconciliar_sem_status_da_api_deriva_das_datas(caso, campos, renovacao, esperado):
    linha = _linha_vazia()
    assinatura_service.reconciliar(_DbFalso(), linha, _tx(**campos), renovacao, AGORA)
    assert linha.status == esperado, caso


def test_active_vencido_sem_notificacao_vale_expired():
    linha = _linha_vazia()
    assinatura_service.reconciliar(
        _DbFalso(), linha, _tx(expira_em=AGORA + timedelta(days=1)), None, AGORA, status_apple=1
    )
    assert linha.status == "active"
    # Nenhuma notificação chegou; dois dias depois já não há acesso.
    assert assinatura_service.calcular_acesso(linha, AGORA + timedelta(days=2)) == ("expired", False)


# ===================================================== 2. /transacoes


def _transacao_do_usuario(amb, user_id=USER_A, nome="jws-a", **campos):
    token = amb.token(user_id)
    tx = _tx(app_account_token=token, **campos)
    return amb.fake.jws(nome, tx), tx


def test_transacoes_liga_e_devolve_o_estado(ambiente, monkeypatch):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    jws, tx = _transacao_do_usuario(ambiente)
    ambiente.fake.estado(tx, 1, _ren(renovacao_automatica=True))

    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 200, resposta.text
    corpo = resposta.json()
    assert (corpo["status"], corpo["tem_acesso"], corpo["produto"]) == ("active", True, MENSAL)
    linha = ambiente.linha(USER_A)
    assert linha.original_transaction_id == "otid-1"
    assert linha.ambiente == "Production"
    assert linha.renovacao_automatica is True
    assert ambiente.fake.consultas == [("Production", "otid-1")]

    # GET devolve o mesmo
    assert ambiente.como(USER_A).get("/api/assinatura").json()["status"] == "active"


def test_transacoes_repetir_nao_duplica(ambiente):
    import models

    jws, tx = _transacao_do_usuario(ambiente)
    ambiente.fake.estado(tx, 1)
    client = ambiente.como(USER_A)
    primeira = client.post("/api/assinatura/transacoes", json={"jws": jws})
    segunda = client.post("/api/assinatura/transacoes", json={"jws": jws})
    assert primeira.status_code == segunda.status_code == 200
    assert primeira.json() == segunda.json()
    assert ambiente.session.query(models.Assinatura).count() == 1


def test_transacoes_sandbox_aceito_e_gravado(ambiente):
    token = ambiente.token(USER_A)
    tx = _tx(app_account_token=token, ambiente="Sandbox")
    jws = ambiente.fake.jws("jws-sandbox", tx, ambiente="Sandbox")
    ambiente.fake.estado(tx, 1, ambiente="Sandbox")
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 200, resposta.text
    assert ambiente.linha(USER_A).ambiente == "Sandbox"
    assert ambiente.fake.consultas == [("Sandbox", "otid-1")]


def test_transacoes_sandbox_recusado_quando_desligado(ambiente, monkeypatch):
    monkeypatch.setenv("APPLE_ACEITA_SANDBOX", "false")
    token = ambiente.token(USER_A)
    jws = ambiente.fake.jws("jws-sandbox", _tx(app_account_token=token), ambiente="Sandbox")
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 400
    assert ambiente.linha(USER_A).original_transaction_id is None


def test_transacoes_jws_invalido_400(ambiente):
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": "adulterado"})
    assert resposta.status_code == 400
    assert resposta.json()["error"] == "Comprovante da compra inválido."
    assert ambiente.fake.consultas == []


@pytest.mark.parametrize(
    "campos",
    [
        dict(produto="br.com.softspend.app.outra"),
        dict(tipo="Consumable"),
        dict(bundle_id="br.com.outroapp"),
    ],
    ids=["productId desconhecido", "não é assinatura", "outro app"],
)
def test_transacoes_produto_tipo_ou_app_errado_400(ambiente, campos):
    jws, _ = _transacao_do_usuario(ambiente, **campos)
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 400
    assert ambiente.linha(USER_A).original_transaction_id is None


def test_transacoes_token_de_outro_usuario_409(ambiente):
    jws, _ = _transacao_do_usuario(ambiente, user_id=USER_B)  # token do B
    ambiente.token(USER_A)
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 409
    assert resposta.json()["error"] == "Esta assinatura pertence a outra conta do SoftSpend."
    assert ambiente.linha(USER_A).original_transaction_id is None
    assert ambiente.linha(USER_B).original_transaction_id is None


def test_transacoes_compra_ja_de_outro_usuario_409(ambiente):
    # B liga a compra primeiro (com o token dele).
    jws_b, tx_b = _transacao_do_usuario(ambiente, user_id=USER_B, nome="jws-b")
    ambiente.fake.estado(tx_b, 1)
    assert ambiente.como(USER_B).post("/api/assinatura/transacoes", json={"jws": jws_b}).status_code == 200

    # A tenta a mesma compra original com um JWS que traz o token de A.
    jws_a, _ = _transacao_do_usuario(ambiente, user_id=USER_A, nome="jws-a")
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws_a})
    assert resposta.status_code == 409
    assert ambiente.linha(USER_B).original_transaction_id == "otid-1"
    assert ambiente.linha(USER_A).original_transaction_id is None


def test_transacoes_sem_token_e_livre_liga_ao_usuario(ambiente):
    tx = _tx(app_account_token=None)
    jws = ambiente.fake.jws("jws-sem-token", tx)
    ambiente.fake.estado(tx, 1)
    token = ambiente.token(USER_A)
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 200, resposta.text
    linha = ambiente.linha(USER_A)
    assert linha.original_transaction_id == "otid-1"
    assert linha.app_account_token == token


def test_transacoes_sem_token_e_sem_linha_cria_a_linha(ambiente):
    tx = _tx(app_account_token=None)
    jws = ambiente.fake.jws("jws-sem-token", tx)
    ambiente.fake.estado(tx, 1)
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 200, resposta.text
    assert ambiente.linha(USER_A).original_transaction_id == "otid-1"


def test_transacoes_sem_token_e_de_outro_409(ambiente):
    jws_b, tx_b = _transacao_do_usuario(ambiente, user_id=USER_B, nome="jws-b")
    ambiente.fake.estado(tx_b, 1)
    assert ambiente.como(USER_B).post("/api/assinatura/transacoes", json={"jws": jws_b}).status_code == 200

    jws = ambiente.fake.jws("jws-sem-token", _tx(app_account_token=None))
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 409


def test_transacoes_apple_fora_do_ar_503_sem_gravar(ambiente):
    import models

    jws, tx = _transacao_do_usuario(ambiente)
    ambiente.fake.estado(tx, 1)
    ambiente.fake.fora_do_ar = True
    antes = ambiente.linha(USER_A)
    atualizado = antes.atualizado_em

    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 503
    assert resposta.json()["error"] == "Tente de novo em instantes."
    depois = ambiente.linha(USER_A)
    assert (depois.status, depois.original_transaction_id, depois.atualizado_em) == (
        "none", None, atualizado,
    )
    assert ambiente.session.query(models.Assinatura).count() == 1


def test_transacoes_apple_fora_do_ar_sem_linha_nao_cria_nada(ambiente):
    import models

    tx = _tx(app_account_token=None)
    jws = ambiente.fake.jws("jws-sem-token", tx)
    ambiente.fake.fora_do_ar = True
    assert ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws}).status_code == 503
    assert ambiente.session.query(models.Assinatura).count() == 0


def test_transacoes_usa_o_estado_atual_da_api(ambiente):
    """O JWS enviado pode ser antigo; o estado vem da Apple."""
    jws, tx = _transacao_do_usuario(ambiente)
    ambiente.fake.estado(_tx(expira_em=_agora_real() - timedelta(days=2)), 2)
    resposta = ambiente.como(USER_A).post("/api/assinatura/transacoes", json={"jws": jws})
    assert resposta.status_code == 200
    assert resposta.json()["status"] == "expired"


def test_transacoes_exige_login(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv("REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!")
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    resposta = TestClient(app).post("/api/assinatura/transacoes", json={"jws": "x"})
    assert resposta.status_code == 401


# ========================================================== 3. webhook


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
    jws, tx = _transacao_do_usuario(amb, user_id=user_id, nome=f"jws-{user_id}", **campos)
    amb.fake.estado(tx, status)
    assert amb.como(user_id).post("/api/assinatura/transacoes", json={"jws": jws}).status_code == 200
    amb.fake.consultas.clear()
    return tx


@pytest.mark.parametrize(
    "corpo",
    [{"signedPayload": "adulterado"}, {"signedPayload": ""}, {"outro": "x"}, ["x"]],
    ids=["assinatura inválida", "vazio", "sem campo", "não é objeto"],
)
def test_webhook_invalido_400_e_nada_gravado(ambiente, corpo):
    resposta = TestClient(ambiente.app).post("/api/webhooks/apple", json=corpo)
    assert resposta.status_code == 400
    assert ambiente.notificacoes() == []


def test_webhook_corpo_que_nao_e_json_400(ambiente):
    resposta = TestClient(ambiente.app).post(
        "/api/webhooks/apple", content=b"nao-e-json", headers={"content-type": "application/json"}
    )
    assert resposta.status_code == 400


def test_webhook_reconcilia_pela_api(ambiente):
    tx = _ligar(ambiente)
    vencida = _tx(expira_em=_agora_real() - timedelta(days=1))
    ambiente.fake.estado(vencida, 2)
    payload = ambiente.fake.payload("p-1", _notif(tipo="EXPIRED", subtipo="VOLUNTARY", transacao=tx))

    assert _webhook(ambiente, payload).status_code == 200
    assert ambiente.linha(USER_A).status == "expired"
    assert ambiente.fake.consultas == [("Production", "otid-1")]
    [registro] = ambiente.notificacoes()
    assert (registro.notification_uuid, registro.tipo, registro.subtipo, registro.original_transaction_id) == (
        "n-1", "EXPIRED", "VOLUNTARY", "otid-1",
    )


def test_webhook_uuid_repetido_200_sem_efeito(ambiente):
    tx = _ligar(ambiente)
    payload = ambiente.fake.payload("p-1", _notif(transacao=tx))
    assert _webhook(ambiente, payload).status_code == 200
    consultas = list(ambiente.fake.consultas)
    ambiente.fake.estado(_tx(expira_em=_agora_real() - timedelta(days=1)), 2)

    assert _webhook(ambiente, payload).status_code == 200
    assert ambiente.fake.consultas == consultas  # não reconciliou de novo
    assert ambiente.linha(USER_A).status == "active"
    assert len(ambiente.notificacoes()) == 1


def test_webhook_transacao_desconhecida_200_e_registrada(ambiente):
    payload = ambiente.fake.payload(
        "p-1", _notif(tipo="SUBSCRIBED", subtipo="INITIAL_BUY", transacao=_tx(original_transaction_id="otid-x"))
    )
    assert _webhook(ambiente, payload).status_code == 200
    [registro] = ambiente.notificacoes()
    assert registro.original_transaction_id == "otid-x"
    assert ambiente.fake.consultas == []


def test_webhook_liga_pelo_app_account_token(ambiente):
    """Compra ainda não enviada pelo app: a notificação chega antes."""
    token = ambiente.token(USER_A)
    tx = _tx(app_account_token=token)
    ambiente.fake.estado(tx, 1)
    payload = ambiente.fake.payload("p-1", _notif(tipo="SUBSCRIBED", subtipo="INITIAL_BUY", transacao=tx))
    assert _webhook(ambiente, payload).status_code == 200
    linha = ambiente.linha(USER_A)
    assert (linha.status, linha.original_transaction_id) == ("active", "otid-1")


def test_webhook_notificacao_antiga_nao_desfaz_estado_novo_com_api(ambiente):
    tx = _ligar(ambiente)
    ambiente.fake.estado(_tx(expira_em=_agora_real() - timedelta(days=1)), 2)
    assert _webhook(ambiente, ambiente.fake.payload("p-exp", _notif(uuid="n-exp", tipo="EXPIRED", transacao=tx))).status_code == 200
    assert ambiente.linha(USER_A).status == "expired"

    # Um DID_RENEW atrasado chega: a API ainda diz expirada.
    atrasada = _notif(uuid="n-velha", tipo="DID_RENEW", transacao=tx, assinada_em=_agora_real() - timedelta(days=3))
    assert _webhook(ambiente, ambiente.fake.payload("p-velha", atrasada)).status_code == 200
    assert ambiente.linha(USER_A).status == "expired"


def test_webhook_api_fora_do_ar_so_aplica_notificacao_mais_nova(ambiente):
    tx = _ligar(ambiente)  # active, atualizado_em = agora
    ambiente.fake.fora_do_ar = True
    vencida = _tx(expira_em=_agora_real() - timedelta(days=1))

    antiga = _notif(uuid="n-antiga", tipo="EXPIRED", transacao=vencida, status=2,
                    assinada_em=_agora_real() - timedelta(hours=1))
    assert _webhook(ambiente, ambiente.fake.payload("p-antiga", antiga)).status_code == 200
    assert ambiente.linha(USER_A).status == "active"

    nova = _notif(uuid="n-nova", tipo="EXPIRED", transacao=vencida, status=2,
                  assinada_em=_agora_real() + timedelta(minutes=1))
    assert _webhook(ambiente, ambiente.fake.payload("p-nova", nova)).status_code == 200
    assert ambiente.linha(USER_A).status == "expired"
    assert {n.notification_uuid for n in ambiente.notificacoes()} == {"n-antiga", "n-nova"}


def test_webhook_test_200_sem_reconciliar(ambiente):
    _ligar(ambiente)
    payload = ambiente.fake.payload("p-test", _notif(uuid="n-test", tipo="TEST"))
    assert _webhook(ambiente, payload).status_code == 200
    assert ambiente.fake.consultas == []
    assert [n.tipo for n in ambiente.notificacoes()] == ["TEST"]


@pytest.mark.parametrize("tipo", sorted(assinatura_service.SO_REGISTRA - {"TEST"}))
def test_webhook_tipos_que_so_registram(ambiente, tipo):
    tx = _ligar(ambiente)
    ambiente.fake.estado(_tx(expira_em=_agora_real() - timedelta(days=1)), 2)
    payload = ambiente.fake.payload("p", _notif(tipo=tipo, transacao=tx))
    assert _webhook(ambiente, payload).status_code == 200
    assert ambiente.fake.consultas == []
    assert ambiente.linha(USER_A).status == "active"
    assert [n.tipo for n in ambiente.notificacoes()] == [tipo]


def test_webhook_falha_interna_500_e_uuid_nao_gravado(ambiente, monkeypatch):
    tx = _ligar(ambiente)
    payload = ambiente.fake.payload("p-1", _notif(transacao=tx))
    original = assinatura_service.reconciliar

    def quebrar(*args, **kwargs):
        raise RuntimeError("banco caiu")

    monkeypatch.setattr(assinatura_service, "reconciliar", quebrar)
    assert _webhook(ambiente, payload).status_code == 500
    assert ambiente.notificacoes() == []

    # A Apple repete e agora dá certo: não é tratada como duplicata.
    monkeypatch.setattr(assinatura_service, "reconciliar", original)
    assert _webhook(ambiente, payload).status_code == 200
    assert len(ambiente.notificacoes()) == 1


def test_webhook_sandbox_reconcilia_na_api_do_sandbox(ambiente):
    token = ambiente.token(USER_A)
    tx = _tx(app_account_token=token, ambiente="Sandbox")
    ambiente.fake.estado(tx, 1, ambiente="Sandbox")
    payload = ambiente.fake.payload("p-sb", _notif(tipo="SUBSCRIBED", transacao=tx), ambiente="Sandbox")
    assert _webhook(ambiente, payload).status_code == 200
    assert ambiente.fake.consultas == [("Sandbox", "otid-1")]
    assert ambiente.linha(USER_A).ambiente == "Sandbox"


# =========================================== 4. registro das rotas e 503


@pytest.mark.parametrize("billing", [None, "off", "on"])
def test_rotas_registradas_sem_open_finance_e_com_qualquer_billing(importar_main, monkeypatch, billing):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv("REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!")
    if billing is None:
        monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    else:
        monkeypatch.setenv("BILLING_ENFORCEMENT", billing)
    main = importar_main(False)
    rotas = {(rota.path, metodo) for rota in main.app.routes for metodo in getattr(rota, "methods", ())}
    assert ("/api/assinatura/transacoes", "POST") in rotas
    assert ("/api/webhooks/apple", "POST") in rotas
    # O webhook responde sem login (400 = chegou na rota, não 401/404).
    resposta = TestClient(main.app).post("/api/webhooks/apple", json={"signedPayload": ""})
    assert resposta.status_code == 400


def test_sem_variaveis_apple_503_e_get_continua(monkeypatch, tmp_path):
    """Com as fábricas reais e sem `APPLE_*`: 503; `GET /api/assinatura` segue."""
    from database import Base, get_db
    from dependencies import get_current_user_id
    import limiter as limiter_module
    import models

    for nome in ("APPLE_BUNDLE_ID", "APPLE_APP_ID", "APPLE_ISSUER_ID", "APPLE_KEY_ID",
                 "APPLE_PRIVATE_KEY", "APPLE_PRIVATE_KEY_PATH"):
        monkeypatch.delenv(nome, raising=False)
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv("REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!")
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/sem.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add(models.User(id=USER_A, nome="A", username="a", email="a@e.com", senha_hash="h"))
    session.commit()
    app.dependency_overrides[get_db] = lambda: session
    app.dependency_overrides[get_current_user_id] = lambda: USER_A
    try:
        client = TestClient(app)
        assert client.post("/api/assinatura/transacoes", json={"jws": "x"}).status_code == 503
        assert client.post("/api/webhooks/apple", json={"signedPayload": "x"}).status_code == 503
        assert client.get("/api/assinatura").status_code == 200
        assert session.query(models.AppleNotificacao).count() == 0
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()
    assert apple_service.configurada() is False


# ======================================================== 5. job diário


def _semear_job(session):
    import models

    agora = _agora_real()
    linhas = {
        "ativa": dict(status="active", expira_em=agora + timedelta(days=10), ambiente="Production"),
        "carencia": dict(status="grace", expira_em=agora - timedelta(days=1),
                         carencia_ate=agora + timedelta(days=5), ambiente="Production"),
        "expirou_3_dias": dict(status="expired", expira_em=agora - timedelta(days=3), ambiente="Sandbox"),
        "expirou_30_dias": dict(status="expired", expira_em=agora - timedelta(days=30), ambiente="Production"),
        "revogada_antiga": dict(status="revoked", expira_em=agora - timedelta(days=60), ambiente="Production"),
        "sem_compra": dict(status="none", ambiente=None, sem_otid=True),
    }
    for nome, campos in linhas.items():
        sem_otid = campos.pop("sem_otid", False)
        session.add(models.User(id=nome, nome=nome, username=nome, email=f"{nome}@e.com", senha_hash="h"))
        session.add(models.Assinatura(
            user_id=nome, original_transaction_id=None if sem_otid else f"otid-{nome}", **campos
        ))
    session.commit()


def test_job_reconcilia_so_as_linhas_certas_no_ambiente_da_linha(ambiente):
    _semear_job(ambiente.session)
    for nome, status, ambiente_apple in (
        ("ativa", 2, "Production"), ("carencia", 1, "Production"), ("expirou_3_dias", 1, "Sandbox"),
    ):
        ambiente.fake.estado(
            _tx(original_transaction_id=f"otid-{nome}", expira_em=_agora_real() + timedelta(days=30)
                if status == 1 else _agora_real() - timedelta(days=1)),
            status, ambiente=ambiente_apple,
        )
    pausas = []
    contagem = assinatura_job.executar(ambiente.session, pausa=0.5, dormir=pausas.append)

    assert sorted(ambiente.fake.consultas) == sorted([
        ("Production", "otid-ativa"), ("Production", "otid-carencia"), ("Sandbox", "otid-expirou_3_dias"),
    ])
    assert contagem == {"total": 3, "reconciliadas": 3, "sem_estado": 0, "falhas": 0}
    assert pausas == [0.5, 0.5]
    assert ambiente.linha("ativa").status == "expired"
    assert ambiente.linha("carencia").status == "active"
    assert ambiente.linha("expirou_3_dias").status == "active"
    assert ambiente.linha("expirou_30_dias").status == "expired"


def test_job_uma_falha_nao_impede_as_outras(ambiente):
    _semear_job(ambiente.session)
    for nome, amb_apple in (("ativa", "Production"), ("carencia", "Production"), ("expirou_3_dias", "Sandbox")):
        ambiente.fake.estado(_tx(original_transaction_id=f"otid-{nome}"), 1, ambiente=amb_apple)
    ambiente.fake.falhar.add("otid-ativa")

    contagem = assinatura_job.executar(ambiente.session, pausa=0)
    assert contagem["falhas"] == 1
    assert contagem["reconciliadas"] == 2
    assert ambiente.linha("ativa").status == "active"  # intocada
    assert ambiente.linha("carencia").status == "active"
    assert ambiente.linha("expirou_3_dias").status == "active"


def test_job_sem_configuracao_sai_com_2(monkeypatch):
    monkeypatch.delenv("APPLE_BUNDLE_ID", raising=False)
    monkeypatch.setattr("logging_config.setup_logging", lambda *a, **k: None)
    assert assinatura_job.main() == 2


# ===================================== 6. replay de POST /ciclos sem acesso


def _post_ciclo(client, client_id):
    return client.post(
        "/ciclos",
        json={
            "client_id": client_id,
            "valor_total": "700.00",
            "periodo": "01/11/2026 a 07/11/2026",
            "diaria": "100.00",
            "titulo": "Semana",
        },
    )


def test_replay_de_ciclo_existente_passa_sem_assinatura(ambiente, monkeypatch):
    import models

    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    ciclo = models.Ciclo(
        id_usuario=USER_A, client_id="ja-existe", valor_total=700, gasto_total=0,
        periodo="01/11/2026 a 07/11/2026", diaria=100, titulo="Semana",
    )
    ambiente.session.add(ciclo)
    ambiente.session.commit()
    client = ambiente.como(USER_A)

    repetido = _post_ciclo(client, "ja-existe")
    assert repetido.status_code == 200, repetido.text
    assert repetido.json()["id"] == ciclo.id
    assert ambiente.session.query(models.Ciclo).count() == 1

    novo = _post_ciclo(client, "novo")
    assert novo.status_code == 403
    assert novo.json()["error"] == "subscription_required"
    assert ambiente.session.query(models.Ciclo).count() == 1


def test_replay_nao_vale_para_client_id_de_outro_usuario(ambiente, monkeypatch):
    import models

    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    ambiente.session.add(models.Ciclo(
        id_usuario=USER_B, client_id="do-b", valor_total=700, gasto_total=0,
        periodo="01/11/2026 a 07/11/2026", diaria=100, titulo="Semana",
    ))
    ambiente.session.commit()
    assert _post_ciclo(ambiente.como(USER_A), "do-b").status_code == 403


# ============================================== adaptador da biblioteca


def test_transacao_da_biblioteca_converte_campos():
    payload = SimpleNamespace(
        originalTransactionId="2000001", transactionId="2000009", bundleId=BUNDLE,
        productId=MENSAL, type=SimpleNamespace(value=TIPO), rawType=None,
        appAccountToken="ABCDEF00-0000-0000-0000-000000000001",
        expiresDate=1_794_571_200_000, rawOfferType=1, offerDiscountType=None,
        rawOfferDiscountType="FREE_TRIAL", revocationDate=None, rawEnvironment="Sandbox",
        signedDate=1_794_571_200_000,
    )
    tx = apple_service.transacao_da_biblioteca(payload)
    assert tx.original_transaction_id == "2000001"
    assert tx.tipo == TIPO
    assert tx.app_account_token == "abcdef00-0000-0000-0000-000000000001"
    assert tx.expira_em == datetime(2026, 11, 13, 12, 0, 0)
    assert (tx.offer_type, tx.offer_discount_type, tx.ambiente) == (1, "FREE_TRIAL", "Sandbox")
    assert assinatura_service.traduzir_status(1, tx, None, AGORA) == "trial"


def test_renovacao_da_biblioteca_converte_campos():
    payload = SimpleNamespace(
        rawAutoRenewStatus=0, gracePeriodExpiresDate=1_794_571_200_000,
        autoRenewProductId=ANUAL, isInBillingRetryPeriod=True,
    )
    ren = apple_service.renovacao_da_biblioteca(payload)
    assert ren.renovacao_automatica is False
    assert ren.carencia_ate == datetime(2026, 11, 13, 12, 0, 0)
    assert (ren.produto_renovacao, ren.em_nova_tentativa) == (ANUAL, True)


def test_verificacao_tenta_production_e_depois_sandbox(monkeypatch):
    fake = FakeApple()
    monkeypatch.setattr(apple_service, "obter_verificador", fake.verificador)
    monkeypatch.delenv("APPLE_ACEITA_SANDBOX", raising=False)
    fake.jws("prod", _tx(), "Production")
    fake.jws("sb", _tx(), "Sandbox")
    assert apple_service.verificar_transacao("prod")[1] == "Production"
    assert apple_service.verificar_transacao("sb")[1] == "Sandbox"
    with pytest.raises(ComprovanteInvalido):
        apple_service.verificar_transacao("desconhecido")
    monkeypatch.setenv("APPLE_ACEITA_SANDBOX", "false")
    with pytest.raises(ComprovanteInvalido):
        apple_service.verificar_transacao("sb")
