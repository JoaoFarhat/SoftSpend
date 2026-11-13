"""Testes da tarefa S2 da spec cartao-sem-open-finance (§2.4, §2.5, §2.6).

Cobre a prévia da conciliação (`ciclo_id` no `POST /api/faturas/ler`), a
gravação idempotente (`POST /api/faturas`), `/conciliar`, `GET`, `DELETE`,
as rotas de match e a migration `f2c4e6a8b0d2`. Os envios usam OFX, que não
depende do Gemini.
"""

import importlib
import importlib.util
import sys
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

USER_A = "user-1"
USER_B = "user-2"
INICIO = date(2026, 10, 1)
FIM = date(2026, 10, 7)


# ---------------------------------------------------------------- helpers


def _ofx(
    transacoes,
    emissor="Banco Teste",
    dtend="20261007",
    dtasof="20261020",
    balamt="500.00",
) -> bytes:
    """Monta um OFX mínimo. `transacoes`: (TRNTYPE, DTPOSTED, TRNAMT, MEMO)."""
    linhas = [
        "OFXHEADER:100",
        "DATA:OFXSGML",
        "VERSION:102",
        "<OFX>",
        "<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS>"
        f"<DTSERVER>20261020<LANGUAGE>POR<FI><ORG>{emissor}</FI></SONRS>"
        "</SIGNONMSGSRSV1>",
        "<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL"
        "<CCACCTFROM><ACCTID>1234</CCACCTFROM>",
        f"<BANKTRANLIST><DTSTART>20260901000000<DTEND>{dtend}000000",
    ]
    for i, (trntype, dtposted, trnamt, memo) in enumerate(transacoes):
        linhas.append(
            f"<STMTTRN><TRNTYPE>{trntype}<DTPOSTED>{dtposted}000000"
            f"<TRNAMT>{trnamt}<FITID>t{i}<MEMO>{memo}</STMTTRN>"
        )
    linhas += [
        "</BANKTRANLIST>",
        f"<LEDGERBAL><BALAMT>{balamt}<DTASOF>{dtasof}000000</LEDGERBAL>",
        "</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>",
    ]
    return "\n".join(linhas).encode()


def _data(d: date) -> str:
    return d.strftime("%Y%m%d")


def _dt(d: date) -> datetime:
    return datetime.combine(d, time.min, tzinfo=timezone.utc)


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

    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/fatura_s2.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(
                id=USER_A, nome="A", username="a", email="a@e.com",
                senha_hash="hash",
            ),
            models.User(
                id=USER_B, nome="B", username="b", email="b@e.com",
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


def _ciclo(session, user_id=USER_A, inicio=INICIO, dias=FIM - INICIO + timedelta(days=1)):
    import models

    ciclo = models.Ciclo(id_usuario=user_id, titulo="Viagem")
    session.add(ciclo)
    session.flush()
    lista = [
        models.Dia(
            ciclo_id=ciclo.id,
            data=_dt(inicio + timedelta(days=i)),
            saldo=Decimal("100.00"),
        )
        for i in range(dias.days)
    ]
    session.add_all(lista)
    session.flush()
    return ciclo, lista


def _gasto(session, dia, titulo, valor):
    import models

    gasto = models.Gasto(
        dia_id=dia.id,
        titulo=titulo,
        valor=Decimal(str(valor)),
        categoria="ALIMENTACAO",
    )
    session.add(gasto)
    session.flush()
    return gasto


def _ler(client, conteudo: bytes, **form) -> dict:
    resposta = client.post(
        "/api/faturas/ler",
        files={"arquivo": ("fatura.ofx", conteudo, "application/ofx")},
        data={k: str(v) for k, v in form.items() if v is not None},
    )
    assert resposta.status_code == 200, resposta.text
    return resposta.json()


def _gravar(client, lida: dict) -> dict:
    resposta = client.post("/api/faturas", json=lida)
    assert resposta.status_code == 200, resposta.text
    return resposta.json()


# ------------------------------------------------------------------ prévia


def test_previa_valor_e_data_iguais_auto_matched(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    gasto = _gasto(ambiente.session, dias[0], "SUPERMERCADO X", "100.00")

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO X")]),
        ciclo_id=ciclo.id,
    )

    compra = corpo["compras"][0]
    assert compra["dentro_da_viagem"] is True
    assert compra["dia_id"] == dias[0].id
    assert compra["match"] == {
        "gasto_id": gasto.id,
        "score": 100,
        "status": "AUTO_MATCHED",
    }


def test_previa_compra_alguns_dias_depois(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    gasto = _gasto(ambiente.session, dias[0], "PADARIA", "40.00")

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", _data(INICIO + timedelta(days=3)), "-40.00", "PADARIA")]),
        ciclo_id=ciclo.id,
    )

    # 60 (valor) + 5 (3 dias de distância) + 20 (texto) = 85 → AUTO_MATCHED
    assert corpo["compras"][0]["match"] == {
        "gasto_id": gasto.id,
        "score": 85,
        "status": "AUTO_MATCHED",
    }


def test_previa_valor_diferente_sem_vinculo(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    _gasto(ambiente.session, dias[0], "SUPERMERCADO X", "99.00")

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO X")]),
        ciclo_id=ciclo.id,
    )

    assert corpo["compras"][0]["match"] is None


def test_previa_fora_da_janela_sem_vinculo(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    _gasto(ambiente.session, dias[6], "RESTAURANTE", "80.00")  # 07/10

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", _data(INICIO), "-80.00", "RESTAURANTE")]),  # 01/10
        ciclo_id=ciclo.id,
    )

    compra = corpo["compras"][0]
    assert compra["dentro_da_viagem"] is True
    assert compra["dia_id"] == dias[0].id
    assert compra["match"] is None


def test_previa_empate_entre_gastos_vai_para_review(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    g1 = _gasto(ambiente.session, dias[0], "LOJA A", "50.00")
    g2 = _gasto(ambiente.session, dias[0], "LOJA A", "50.00")

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", _data(INICIO), "-50.00", "LOJA A")]),
        ciclo_id=ciclo.id,
    )

    match = corpo["compras"][0]["match"]
    assert match["status"] == "REVIEW"
    assert match["score"] == 100
    assert match["gasto_id"] in (g1.id, g2.id)


def test_previa_um_gasto_casa_com_uma_compra_so(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    _gasto(ambiente.session, dias[0], "LOJA A", "50.00")

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx(
            [
                ("DEBIT", _data(INICIO), "-50.00", "LOJA A"),
                ("DEBIT", _data(INICIO), "-50.00", "LOJA A"),
            ]
        ),
        ciclo_id=ciclo.id,
    )

    matches = [c["match"] for c in corpo["compras"]]
    assert sum(1 for m in matches if m) == 1
    assert matches[0] is not None
    assert matches[1] is None


def test_previa_gasto_de_outra_viagem_ou_usuario_nao_entra(ambiente):
    ciclo, _ = _ciclo(ambiente.session)
    outro_ciclo, outros_dias = _ciclo(ambiente.session, user_id=USER_B)
    _gasto(ambiente.session, outros_dias[0], "LOJA A", "50.00")
    _, dias_outra = _ciclo(
        ambiente.session, inicio=date(2026, 11, 1), dias=timedelta(days=7)
    )
    _gasto(ambiente.session, dias_outra[0], "LOJA A", "50.00")

    client = ambiente.como(USER_A)
    corpo = _ler(
        client,
        _ofx([("DEBIT", _data(INICIO), "-50.00", "LOJA A")]),
        ciclo_id=ciclo.id,
    )
    assert corpo["compras"][0]["match"] is None

    # Ciclo de outro usuário: 404.
    resposta = client.post(
        "/api/faturas/ler",
        files={"arquivo": ("fatura.ofx", _ofx([]), "application/ofx")},
        data={"ciclo_id": str(outro_ciclo.id)},
    )
    assert resposta.status_code == 404


def test_previa_compra_fora_das_datas_da_viagem(ambiente):
    ciclo, _ = _ciclo(ambiente.session)

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", "20261020", "-30.00", "DEPOIS DA VIAGEM")]),
        ciclo_id=ciclo.id,
    )

    compra = corpo["compras"][0]
    assert compra["dentro_da_viagem"] is False
    assert compra["dia_id"] is None
    assert compra["match"] is None


def test_previa_estorno_e_encargo_nunca_casam(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    _gasto(ambiente.session, dias[0], "LOJA A", "50.00")
    _gasto(ambiente.session, dias[0], "TARIFA", "10.00")

    corpo = _ler(
        ambiente.como(USER_A),
        _ofx(
            [
                ("CREDIT", _data(INICIO), "50.00", "LOJA A"),
                ("FEE", _data(INICIO), "10.00", "TARIFA"),
            ]
        ),
        ciclo_id=ciclo.id,
    )

    assert [c["tipo"] for c in corpo["compras"]] == ["ESTORNO", "ENCARGO"]
    assert [c["match"] for c in corpo["compras"]] == [None, None]


def test_previa_sem_ciclo_id_nao_marca_nada(ambiente):
    corpo = _ler(
        ambiente.como(USER_A),
        _ofx([("DEBIT", _data(INICIO), "-50.00", "LOJA A")]),
    )
    compra = corpo["compras"][0]
    assert compra["dentro_da_viagem"] is False
    assert compra["match"] is None


# --------------------------------------------------------------- gravação


def test_post_faturas_grava_sem_duplicar_e_atualiza_total(ambiente):
    import models

    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx(
            [
                ("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO"),
                ("DEBIT", _data(INICIO + timedelta(days=1)), "-32.40", "UBER"),
            ],
            balamt="132.40",
        ),
    )

    detalhe = _gravar(client, lida)
    assert detalhe["bill_id"].startswith("fatura:")
    assert detalhe["total_amount"] == 132.40  # BALAMT do OFX
    assert len(detalhe["transacoes"]) == 2
    assert all(
        t["transaction_id"].startswith("fatura:")
        for t in detalhe["transacoes"]
    )

    # Reimportar não duplica; total diferente atualiza a mesma fatura.
    lida["total_fatura"] = 200.00
    outra_vez = _gravar(client, lida)
    assert outra_vez["id"] == detalhe["id"]
    assert outra_vez["total_amount"] == 200.00

    session = ambiente.session
    assert session.query(models.CreditCardAccount).count() == 1
    assert session.query(models.CreditCardBill).count() == 1
    assert session.query(models.CreditCardTransaction).count() == 2
    cartao = session.query(models.CreditCardAccount).one()
    assert cartao.origem == "FATURA"
    assert cartao.conexao_id is None
    assert cartao.institution_name == "Banco Teste"


def test_post_faturas_compras_identicas_continuam_duas(ambiente):
    import models

    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx(
            [
                ("DEBIT", _data(INICIO), "-50.00", "LOJA A"),
                ("DEBIT", _data(INICIO), "-50.00", "LOJA A"),
            ]
        ),
    )

    detalhe = _gravar(client, lida)
    assert len(detalhe["transacoes"]) == 2
    ids = {t["transaction_id"] for t in detalhe["transacoes"]}
    assert len(ids) == 2
    assert (
        ambiente.session.query(models.CreditCardTransaction).count() == 2
    )


def test_post_faturas_so_grava_as_compras_enviadas(ambiente):
    import models

    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx(
            [
                ("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO"),
                ("DEBIT", _data(INICIO + timedelta(days=1)), "-32.40", "UBER"),
                ("DEBIT", _data(INICIO + timedelta(days=2)), "-10.00", "CAFE"),
            ]
        ),
    )
    lida["compras"] = [c for c in lida["compras"] if c["descricao"] != "UBER"]

    detalhe = _gravar(client, lida)
    assert len(detalhe["transacoes"]) == 2
    assert ambiente.session.query(models.CreditCardTransaction).count() == 2


def test_post_faturas_sem_vencimento_da_422(ambiente):
    """Fatura sem `vencimento` (CSV, OFX sem DTASOF) não tem chave: seria
    achada por `due_date IS NULL` e meses diferentes virariam a mesma
    fatura com o total sobrescrito. Recusa com 422 e não grava nada."""
    import models

    client = ambiente.como(USER_A)
    lida = _ler(client, _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]))
    lida["vencimento"] = None

    resposta = client.post("/api/faturas", json=lida)
    assert resposta.status_code == 422
    assert ambiente.session.query(models.CreditCardBill).count() == 0
    assert ambiente.session.query(models.CreditCardTransaction).count() == 0


def test_post_faturas_limites_do_dto_na_borda(ambiente):
    """O Pydantic recusa antes de montar o corpo todo: `compras` acima de
    `MAXIMO_COMPRAS` e `descricao` acima do teto dão 422, não 413/500."""
    from dtos.fatura import MAXIMO_COMPRAS

    client = ambiente.como(USER_A)
    lida = _ler(client, _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]))

    cheia = dict(lida)
    cheia["compras"] = [lida["compras"][0]] * (MAXIMO_COMPRAS + 1)
    assert client.post("/api/faturas", json=cheia).status_code == 422

    longa = dict(lida)
    longa["compras"] = [dict(lida["compras"][0], descricao="x" * 501)]
    assert client.post("/api/faturas", json=longa).status_code == 422


def test_gravar_fatura_refaz_busca_em_corrida(ambiente, monkeypatch):
    """Duas gravações da mesma fatura no mesmo cartão calculam o mesmo
    `transaction_id`: a segunda bate na unicidade no `flush`, refaz a
    busca e termina sem erro nem duplicata — em vez de 500."""
    import models
    from sqlalchemy.orm import Session as _Session

    from dtos.fatura import CompraLida, FaturaLida
    from services import fatura_service

    session = ambiente.session
    # O cartão precisa já existir comitado e casar com a `lida` (sem emissor
    # nem final): o `account_id` dele entra no hash — com cartões diferentes
    # os `transaction_id` não colidem.
    session.add(
        models.CreditCardAccount(
            user_id=USER_A,
            conexao_id=None,
            origem="FATURA",
            account_id="fatura:cartao-da-corrida",
            institution_name=None,
            number_last4=None,
            name="Cartão importado",
            currency_code="BRL",
        )
    )
    session.commit()

    lida = FaturaLida(
        vencimento=date(2026, 10, 20),
        compras=[
            CompraLida(
                indice=0,
                data=INICIO,
                descricao="CAFE",
                valor=Decimal("10.00"),
            )
        ],
    )

    # A "outra requisição" grava e comita a mesma fatura no meio do nosso
    # primeiro flush — o mesmo furo entre a busca de existentes e o insert.
    engine = session.get_bind()
    flush_real = _Session.flush
    rival_feita = False

    def flush_com_rival(self, *args, **kwargs):
        nonlocal rival_feita
        if self is session and not rival_feita:
            rival_feita = True
            outra = _Session(engine)
            try:
                fatura_service.gravar_fatura(outra, USER_A, lida)
                outra.commit()
            finally:
                outra.close()
        return flush_real(self, *args, **kwargs)

    monkeypatch.setattr(_Session, "flush", flush_com_rival)

    fatura = fatura_service.gravar_fatura(session, USER_A, lida)
    session.commit()

    assert fatura.id is not None
    assert session.query(models.CreditCardAccount).count() == 1
    assert session.query(models.CreditCardBill).count() == 1
    assert session.query(models.CreditCardTransaction).count() == 1


def test_post_faturas_funciona_com_open_finance_desligado(ambiente):
    client = ambiente.como(USER_A)
    detalhe = _gravar(
        client, _ler(client, _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]))
    )
    assert detalhe["id"] > 0
    assert client.get("/api/open-finance/cards").status_code == 404


def test_get_faturas_lista_e_detalhe(ambiente):
    client = ambiente.como(USER_A)
    detalhe = _gravar(
        client, _ler(client, _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]))
    )

    lista = client.get("/api/faturas")
    assert lista.status_code == 200
    assert len(lista.json()) == 1
    assert lista.json()[0]["id"] == detalhe["id"]

    resposta = client.get(f"/api/faturas/{detalhe['id']}")
    assert resposta.status_code == 200
    assert resposta.json()["transacoes"][0]["description"] == "CAFE"


def test_fatura_de_outro_usuario_da_404(ambiente):
    client_a = ambiente.como(USER_A)
    detalhe = _gravar(
        client_a,
        _ler(client_a, _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")])),
    )

    client_b = ambiente.como(USER_B)
    assert client_b.get("/api/faturas").json() == []
    assert client_b.get(f"/api/faturas/{detalhe['id']}").status_code == 404
    assert (
        client_b.post(f"/api/faturas/{detalhe['id']}/conciliar").status_code
        == 404
    )
    assert client_b.delete(f"/api/faturas/{detalhe['id']}").status_code == 404


def test_delete_leva_compras_e_vinculos_mas_nao_gastos(ambiente):
    import models

    ciclo, dias = _ciclo(ambiente.session)
    gasto = _gasto(ambiente.session, dias[0], "SUPERMERCADO", "100.00")
    client = ambiente.como(USER_A)

    lida = _ler(client, _ofx([("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO")]))
    detalhe = _gravar(client, lida)
    assert detalhe["transacoes"][0]["open_finance_match"]["status"] == "AUTO_MATCHED"
    assert (
        ambiente.session.query(models.ExpenseTransactionMatch).count() == 1
    )

    resposta = client.delete(f"/api/faturas/{detalhe['id']}")
    assert resposta.status_code == 200
    assert resposta.json()["id"] == detalhe["id"]

    session = ambiente.session
    assert session.query(models.CreditCardBill).count() == 0
    assert session.query(models.CreditCardTransaction).count() == 0
    assert session.query(models.ExpenseTransactionMatch).count() == 0
    session.refresh(gasto)
    assert gasto.open_finance_match is None


# ------------------------------------------------------------ conciliação


def test_conciliar_casa_gastos_criados_depois(ambiente):
    ciclo, dias = _ciclo(ambiente.session)
    client = ambiente.como(USER_A)

    lida = _ler(client, _ofx([("DEBIT", _data(INICIO), "-100.00", "LOJA Z")]))
    detalhe = _gravar(client, lida)
    assert detalhe["transacoes"][0]["open_finance_match"] is None

    _gasto(ambiente.session, dias[0], "LOJA Z", "100.00")

    resposta = client.post(f"/api/faturas/{detalhe['id']}/conciliar")
    assert resposta.status_code == 200
    match = resposta.json()["transacoes"][0]["open_finance_match"]
    assert match["status"] == "AUTO_MATCHED"
    assert match["score"] == 100


def test_matches_confirmar_e_desvincular(ambiente):
    import models

    client = ambiente.como(USER_A)
    lida = _ler(client, _ofx([("DEBIT", _data(INICIO), "-100.00", "LOJA Z")]))
    detalhe = _gravar(client, lida)

    ciclo, dias = _ciclo(ambiente.session)
    gasto = _gasto(ambiente.session, dias[0], "LOJA Z", "100.00")
    transacao = ambiente.session.query(models.CreditCardTransaction).one()
    match = models.ExpenseTransactionMatch(
        gasto_id=gasto.id,
        cartao_transacao_id=transacao.id,
        status="REVIEW",
        score=70,
        method="RULES",
    )
    ambiente.session.add(match)
    ambiente.session.flush()

    confirmar = client.post(f"/api/faturas/matches/{match.id}/confirm")
    assert confirmar.status_code == 200
    assert confirmar.json()["status"] == "CONFIRMED"
    assert confirmar.json()["confirmed_by_user"] is True

    remover = client.delete(f"/api/faturas/matches/{match.id}")
    assert remover.status_code == 200
    assert (
        ambiente.session.query(models.ExpenseTransactionMatch).count() == 0
    )
    assert client.post("/api/faturas/matches/9999/confirm").status_code == 404


# --------------------------------------------------------------- migration


_CAMINHO_MIGRACAO = (
    Path(__file__).resolve().parents[1]
    / "alembic"
    / "versions"
    / "f2c4e6a8b0d2_fatura_importada_sem_pluggy.py"
)

_DDL_PRE_MIGRACAO = """
CREATE TABLE users (id VARCHAR(36) PRIMARY KEY);
CREATE TABLE open_finance_connections (
    id INTEGER PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    provider VARCHAR(30) NOT NULL,
    item_id VARCHAR(64) NOT NULL
);
CREATE TABLE credit_card_accounts (
    id INTEGER PRIMARY KEY,
    conexao_id INTEGER NOT NULL
        REFERENCES open_finance_connections(id) ON DELETE CASCADE,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    account_id VARCHAR(64) NOT NULL UNIQUE,
    institution_name VARCHAR(255),
    number_last4 VARCHAR(4)
);
CREATE TABLE credit_card_bills (
    id INTEGER PRIMARY KEY,
    cartao_id INTEGER NOT NULL REFERENCES credit_card_accounts(id),
    user_id VARCHAR(36) NOT NULL,
    bill_id VARCHAR(64) NOT NULL UNIQUE
);
CREATE TABLE credit_card_transactions (
    id INTEGER PRIMARY KEY,
    cartao_id INTEGER NOT NULL REFERENCES credit_card_accounts(id),
    user_id VARCHAR(36) NOT NULL,
    transaction_id VARCHAR(64) NOT NULL UNIQUE
);
CREATE TABLE expense_transaction_matches (
    id INTEGER PRIMARY KEY,
    gasto_id INTEGER NOT NULL,
    cartao_transacao_id INTEGER NOT NULL
        REFERENCES credit_card_transactions(id)
);
"""


def _executar_migracao(engine, funcao: str):
    from alembic.migration import MigrationContext
    from alembic.operations import Operations

    spec = importlib.util.spec_from_file_location(
        "f2c4e6a8b0d2_migracao", _CAMINHO_MIGRACAO
    )
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    with engine.connect() as conexao:
        contexto = MigrationContext.configure(conexao)
        with Operations.context(contexto):
            getattr(modulo, funcao)()
        conexao.commit()


def _colunas(engine) -> dict:
    with engine.connect() as conexao:
        return {
            linha[1]: linha
            for linha in conexao.execute(
                text("PRAGMA table_info(credit_card_accounts)")
            )
        }


def _banco_pre_migracao(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path}/migracao.db")
    with engine.begin() as conexao:
        for trecho in _DDL_PRE_MIGRACAO.split(";"):
            if trecho.strip():
                conexao.execute(text(trecho))
    return engine


def test_migration_sobe_e_desce_em_banco_limpo(tmp_path):
    engine = _banco_pre_migracao(tmp_path)

    _executar_migracao(engine, "upgrade")
    colunas = _colunas(engine)
    assert "origem" in colunas
    assert colunas["origem"][3] == 1  # NOT NULL
    assert colunas["conexao_id"][3] == 0  # passa a aceitar NULL

    _executar_migracao(engine, "downgrade")
    colunas = _colunas(engine)
    assert "origem" not in colunas
    assert colunas["conexao_id"][3] == 1  # volta a NOT NULL


def test_migration_preserva_pluggy_e_apaga_fatura_no_downgrade(tmp_path):
    engine = _banco_pre_migracao(tmp_path)
    with engine.begin() as conexao:
        conexao.execute(text("INSERT INTO users (id) VALUES ('user-1')"))
        conexao.execute(
            text(
                "INSERT INTO open_finance_connections "
                "(id, user_id, provider, item_id) "
                "VALUES (1, 'user-1', 'pluggy', 'item-1')"
            )
        )
        conexao.execute(
            text(
                "INSERT INTO credit_card_accounts "
                "(conexao_id, user_id, account_id) VALUES (1, 'user-1', 'acc-1')"
            )
        )

    _executar_migracao(engine, "upgrade")
    with engine.begin() as conexao:
        assert (
            conexao.execute(
                text("SELECT origem FROM credit_card_accounts")
            ).scalar()
            == "PLUGGY"
        )
        conexao.execute(
            text(
                "INSERT INTO credit_card_accounts "
                "(conexao_id, user_id, account_id, origem) "
                "VALUES (NULL, 'user-1', 'acc-fatura', 'FATURA')"
            )
        )

    _executar_migracao(engine, "downgrade")
    with engine.connect() as conexao:
        assert conexao.execute(
            text("SELECT account_id FROM credit_card_accounts")
        ).all() == [("acc-1",)]
        colunas = _colunas(engine)
        assert "origem" not in colunas
        assert colunas["conexao_id"][3] == 1
