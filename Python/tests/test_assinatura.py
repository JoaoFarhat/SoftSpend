"""Assinatura AS1 (`docs/publicacao.md` §1.4): regra, rota, interruptor e bloqueio.

Mesmo padrão de `test_core_api.py`: SQLite em `tmp_path` e
`dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib
import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import Session

from services import assinatura_service
from services.assinatura_service import calcular_acesso

USER_A = "user-a"
USER_B = "user-b"
AGORA = datetime(2026, 11, 13, 12, 0, 0)
UM_SEG = timedelta(seconds=1)

# PNG mínimo: o `filetype` só olha os bytes iniciais.
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + b"\x00" * 32
OFX = (
    "OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\n<OFX>"
    "<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS>"
    "<DTSERVER>20261020<LANGUAGE>POR<FI><ORG>Banco Teste</FI></SONRS>"
    "</SIGNONMSGSRSV1><CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL"
    "<CCACCTFROM><ACCTID>1234</CCACCTFROM><BANKTRANLIST>"
    "<DTSTART>20260901000000<DTEND>20261007000000"
    "<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261002000000<TRNAMT>-10.00"
    "<FITID>t0<MEMO>PADARIA</STMTTRN>"
    "</BANKTRANLIST><LEDGERBAL><BALAMT>10.00<DTASOF>20261020000000</LEDGERBAL>"
    "</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>"
).encode()


def _linha(status, expira_em=None, carencia_ate=None):
    return SimpleNamespace(
        status=status, expira_em=expira_em, carencia_ate=carencia_ate
    )


# ------------------------------------------------------ calcular_acesso


TABELA = [
    # (caso, assinatura, status esperado, acesso esperado)
    ("sem linha", None, "none", False),
    ("linha sem compra", _linha("none"), "none", False),
    ("linha sem compra com data", _linha("none", AGORA + timedelta(days=3)), "none", False),
    # trial
    ("trial dentro do prazo", _linha("trial", AGORA + timedelta(days=14)), "trial", True),
    ("trial no último segundo", _linha("trial", AGORA + UM_SEG), "trial", True),
    ("trial na hora exata do fim", _linha("trial", AGORA), "expired", False),
    ("trial vencido", _linha("trial", AGORA - UM_SEG), "expired", False),
    # active
    ("active dentro do prazo", _linha("active", AGORA + timedelta(days=30)), "active", True),
    ("active no último segundo", _linha("active", AGORA + UM_SEG), "active", True),
    ("active na hora exata do fim", _linha("active", AGORA), "expired", False),
    ("active vencido sem carência", _linha("active", AGORA - timedelta(days=1)), "expired", False),
    ("active sem data", _linha("active"), "expired", False),
    ("active vencido, ainda na carência",
     _linha("active", AGORA - UM_SEG, AGORA + timedelta(days=6)), "grace", True),
    # grace
    ("grace dentro da carência",
     _linha("grace", AGORA - timedelta(days=2), AGORA + timedelta(days=4)), "grace", True),
    ("grace no último segundo da carência",
     _linha("grace", AGORA - timedelta(days=2), AGORA + UM_SEG), "grace", True),
    ("grace na hora exata do fim da carência",
     _linha("grace", AGORA - timedelta(days=2), AGORA), "billing_retry", False),
    ("grace com carência vencida",
     _linha("grace", AGORA - timedelta(days=9), AGORA - timedelta(days=1)), "billing_retry", False),
    ("grace renovada (vencimento novo)",
     _linha("grace", AGORA + timedelta(days=30), AGORA - timedelta(days=1)), "active", True),
    # billing_retry
    ("billing_retry sem carência", _linha("billing_retry", AGORA - timedelta(days=3)), "billing_retry", False),
    ("billing_retry ainda na carência",
     _linha("billing_retry", AGORA - timedelta(days=1), AGORA + timedelta(days=1)), "grace", True),
    # terminais: valem como a Apple gravou
    ("expired", _linha("expired", AGORA - timedelta(days=1)), "expired", False),
    ("expired com data futura", _linha("expired", AGORA + timedelta(days=5)), "expired", False),
    ("revoked", _linha("revoked", AGORA - timedelta(days=1)), "revoked", False),
    ("revoked com data futura",
     _linha("revoked", AGORA + timedelta(days=5), AGORA + timedelta(days=10)), "revoked", False),
]


@pytest.mark.parametrize(
    "assinatura, status, acesso",
    [caso[1:] for caso in TABELA],
    ids=[caso[0] for caso in TABELA],
)
def test_calcular_acesso(assinatura, status, acesso):
    assert calcular_acesso(assinatura, AGORA) == (status, acesso)


def test_tabela_cobre_todos_os_estados():
    assert {caso[2] for caso in TABELA} == set(assinatura_service.ESTADOS)


def test_calcular_acesso_aceita_agora_com_fuso():
    linha = _linha("active", AGORA + UM_SEG)
    # 09:00 em São Paulo (-03:00) é 12:00 UTC, igual ao AGORA.
    agora_sp = datetime(2026, 11, 13, 9, 0, 0, tzinfo=timezone(timedelta(hours=-3)))
    assert calcular_acesso(linha, agora_sp) == ("active", True)
    assert calcular_acesso(linha, agora_sp + UM_SEG) == ("expired", False)


@pytest.mark.parametrize(
    "valor, ligado",
    [(None, False), ("off", False), ("", False), ("true", False), ("on", True), (" ON ", True)],
)
def test_interruptor(monkeypatch, valor, ligado):
    if valor is None:
        monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    else:
        monkeypatch.setenv("BILLING_ENFORCEMENT", valor)
    assert assinatura_service.cobranca_ligada() is ligado


# ------------------------------------------------------------ ambiente


class _Ambiente:
    def __init__(self, app, session):
        self.app = app
        self.session = session

    def como(self, user_id: str) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app)


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    import models
    from services import ocr_service

    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)
    # A IA não é chamada nos testes.
    monkeypatch.setattr(
        ocr_service,
        "extrair_gasto_da_imagem",
        lambda conteudo: {"titulo": "Padaria", "valor": "10.00", "categoria": "ALIMENTACAO"},
    )

    engine = create_engine(f"sqlite:///{tmp_path}/assinatura.db")
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
        yield _Ambiente(app, session)
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


def _ciclo(client, client_id="ciclo-1"):
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


def _quatro_rotas(client, ciclo_id):
    """As 4 rotas bloqueadas: (nome, resposta)."""
    return [
        ("POST /ciclos", _ciclo(client, "ciclo-novo")),
        (
            "POST /gastos/extrair",
            client.post("/gastos/extrair", files={"imagem": ("nota.png", PNG, "image/png")}),
        ),
        (
            "POST /api/faturas/ler",
            client.post(
                "/api/faturas/ler",
                files={"arquivo": ("fatura.ofx", OFX, "application/ofx")},
            ),
        ),
        (
            "GET /ciclos/{id}/export",
            client.get(f"/ciclos/{ciclo_id}/export", params={"formato": "csv"}),
        ),
    ]


def _ciclo_existente(ambiente, user_id=USER_A) -> int:
    """Ciclo criado direto no banco (não depende do interruptor)."""
    import models

    ciclo = models.Ciclo(
        id_usuario=user_id,
        client_id=f"semente-{user_id}",
        valor_total=700,
        gasto_total=0,
        periodo="01/11/2026 a 07/11/2026",
        diaria=100,
        titulo="Semana",
    )
    ambiente.session.add(ciclo)
    ambiente.session.commit()
    return ciclo.id


# ---------------------------------------------------- GET /api/assinatura


def test_get_assinatura_cria_linha_e_repete_o_mesmo_token(ambiente):
    import models

    client = ambiente.como(USER_A)
    assert ambiente.session.query(models.Assinatura).count() == 0

    primeira = client.get("/api/assinatura")
    assert primeira.status_code == 200, primeira.text
    corpo = primeira.json()
    assert corpo["status"] == "none"
    assert corpo["tem_acesso"] is True  # interruptor desligado
    assert corpo["expira_em"] is None
    assert corpo["produto"] is None
    token = corpo["app_account_token"]
    assert len(token) == 36

    segunda = client.get("/api/assinatura").json()
    assert segunda["app_account_token"] == token
    assert ambiente.session.query(models.Assinatura).count() == 1

    # Outro usuário ganha outro token.
    outro = ambiente.como(USER_B).get("/api/assinatura").json()
    assert outro["app_account_token"] != token
    assert ambiente.session.query(models.Assinatura).count() == 2


def test_get_assinatura_com_cobranca_ligada(ambiente, monkeypatch):
    import models

    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    client = ambiente.como(USER_A)
    corpo = client.get("/api/assinatura").json()
    assert (corpo["status"], corpo["tem_acesso"]) == ("none", False)

    linha = ambiente.session.query(models.Assinatura).filter_by(user_id=USER_A).one()
    linha.status = "active"
    linha.produto = "br.com.softspend.app.mensal"
    linha.expira_em = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=10)
    ambiente.session.commit()

    corpo = client.get("/api/assinatura").json()
    assert (corpo["status"], corpo["tem_acesso"]) == ("active", True)
    assert corpo["produto"] == "br.com.softspend.app.mensal"
    assert corpo["expira_em"] is not None


def test_get_assinatura_exige_login(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    assert TestClient(app).get("/api/assinatura").status_code == 401


def test_obter_ou_criar_tolera_corrida(ambiente):
    """Se outra requisição criou a linha no meio, lê a dela em vez de falhar."""
    import models

    outra = Session(ambiente.session.get_bind())
    outra.add(models.Assinatura(user_id=USER_A, app_account_token="token-da-outra"))
    outra.commit()
    outra.close()

    original = assinatura_service.buscar
    chamadas = []

    def buscar_atrasado(db, user_id):
        chamadas.append(user_id)
        return None if len(chamadas) == 1 else original(db, user_id)

    assinatura_service.buscar = buscar_atrasado
    try:
        linha = assinatura_service.obter_ou_criar(ambiente.session, USER_A)
    finally:
        assinatura_service.buscar = original
    assert linha.app_account_token == "token-da-outra"
    assert ambiente.session.query(models.Assinatura).count() == 1


# -------------------------------------------------------------- bloqueio


@pytest.mark.parametrize("valor", [None, "off"])
def test_com_interruptor_desligado_as_4_rotas_funcionam(ambiente, monkeypatch, valor):
    if valor is not None:
        monkeypatch.setenv("BILLING_ENFORCEMENT", valor)
    ciclo_id = _ciclo_existente(ambiente)
    client = ambiente.como(USER_A)
    for nome, resposta in _quatro_rotas(client, ciclo_id):
        assert resposta.status_code == 200, (nome, resposta.text)


def test_com_interruptor_ligado_e_sem_assinatura_as_4_rotas_dao_403(ambiente, monkeypatch):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    ciclo_id = _ciclo_existente(ambiente)
    client = ambiente.como(USER_A)
    for nome, resposta in _quatro_rotas(client, ciclo_id):
        assert resposta.status_code == 403, (nome, resposta.text)
        assert resposta.json()["detail"] == "subscription_required", nome


def test_com_interruptor_ligado_o_resto_continua(ambiente, monkeypatch):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    ciclo_id = _ciclo_existente(ambiente)
    client = ambiente.como(USER_A)

    dia = client.post(
        f"/ciclos/{ciclo_id}/dias",
        json={"client_id": "dia-1", "data": "2026-11-01T00:00:00Z"},
    )
    assert dia.status_code == 200, dia.text

    gasto = client.post(
        f"/dias/{dia.json()['id']}/gastos",
        json={"client_id": "g-1", "titulo": "Almoço", "valor": "25.50", "categoria": "ALIMENTACAO"},
    )
    assert gasto.status_code == 200, gasto.text

    assert client.get("/usuario/ciclos").status_code == 200
    assert client.get("/api/assinatura").status_code == 200

    excluir = client.delete("/auth/conta")
    assert excluir.status_code in (200, 204), excluir.text


def test_com_assinatura_valida_as_4_rotas_funcionam(ambiente, monkeypatch):
    import models

    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    ciclo_id = _ciclo_existente(ambiente)
    ambiente.session.add(
        models.Assinatura(
            user_id=USER_A,
            status="trial",
            expira_em=datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=14),
        )
    )
    ambiente.session.commit()
    client = ambiente.como(USER_A)
    for nome, resposta in _quatro_rotas(client, ciclo_id):
        assert resposta.status_code == 200, (nome, resposta.text)

    # A assinatura de um não vale para o outro.
    outro_ciclo = _ciclo_existente(ambiente, USER_B)
    for nome, resposta in _quatro_rotas(ambiente.como(USER_B), outro_ciclo):
        assert resposta.status_code == 403, nome


def test_interruptor_lido_a_cada_requisicao(ambiente, monkeypatch):
    client = ambiente.como(USER_A)
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    assert _ciclo(client, "c-1").status_code == 403
    monkeypatch.setenv("BILLING_ENFORCEMENT", "off")
    assert _ciclo(client, "c-2").status_code == 200


# ------------------------------------------------------- excluir conta


def test_excluir_conta_apaga_a_assinatura(ambiente):
    import models

    client = ambiente.como(USER_A)
    assert client.get("/api/assinatura").status_code == 200
    ambiente.como(USER_B).get("/api/assinatura")
    assert ambiente.session.query(models.Assinatura).count() == 2

    client = ambiente.como(USER_A)
    assert client.delete("/auth/conta").status_code == 204
    restantes = ambiente.session.query(models.Assinatura).all()
    assert [linha.user_id for linha in restantes] == [USER_B]


# ------------------------------------------------------------ migration


_CAMINHO_MIGRACAO = (
    Path(__file__).resolve().parents[1]
    / "alembic"
    / "versions"
    / "a7c3e9f1b5d2_add_assinaturas.py"
)


def _executar_migracao(engine, funcao: str):
    from alembic.migration import MigrationContext
    from alembic.operations import Operations

    spec = importlib.util.spec_from_file_location("a7c3e9f1b5d2_migracao", _CAMINHO_MIGRACAO)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    assert modulo.down_revision == "f2c4e6a8b0d2"
    with engine.connect() as conexao:
        contexto = MigrationContext.configure(conexao)
        with Operations.context(contexto):
            getattr(modulo, funcao)()
        conexao.commit()


def test_migration_sobe_e_desce(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path}/migracao.db")
    with engine.begin() as conexao:
        conexao.execute(text("CREATE TABLE users (id VARCHAR(36) PRIMARY KEY)"))

    _executar_migracao(engine, "upgrade")
    inspetor = inspect(engine)
    assert {"assinaturas", "apple_notificacoes"} <= set(inspetor.get_table_names())
    colunas = {c["name"] for c in inspetor.get_columns("assinaturas")}
    assert colunas == {
        "id", "user_id", "app_account_token", "original_transaction_id", "produto",
        "ambiente", "status", "expira_em", "carencia_ate", "renovacao_automatica",
        "atualizado_em",
    }
    fks = inspetor.get_foreign_keys("assinaturas")
    assert fks[0]["referred_table"] == "users"
    assert fks[0]["options"].get("ondelete") == "CASCADE"
    unicos = {tuple(u["column_names"]) for u in inspetor.get_unique_constraints("apple_notificacoes")}
    assert ("notification_uuid",) in unicos

    _executar_migracao(engine, "downgrade")
    tabelas = set(inspect(engine).get_table_names())
    assert "assinaturas" not in tabelas
    assert "apple_notificacoes" not in tabelas


def test_modelo_bate_com_a_migration(tmp_path):
    """create_all e a migration geram as mesmas colunas e constraints."""
    from database import Base

    engine_modelo = create_engine(f"sqlite:///{tmp_path}/modelo.db")
    Base.metadata.create_all(engine_modelo)
    engine_migr = create_engine(f"sqlite:///{tmp_path}/migr.db")
    with engine_migr.begin() as conexao:
        conexao.execute(text("CREATE TABLE users (id VARCHAR(36) PRIMARY KEY)"))
    _executar_migracao(engine_migr, "upgrade")

    for tabela in ("assinaturas", "apple_notificacoes"):
        a, b = inspect(engine_modelo), inspect(engine_migr)
        assert {c["name"] for c in a.get_columns(tabela)} == {c["name"] for c in b.get_columns(tabela)}
        assert {u["name"] for u in a.get_unique_constraints(tabela)} == {
            u["name"] for u in b.get_unique_constraints(tabela)
        }
