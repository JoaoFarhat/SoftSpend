"""`DELETE /auth/conta` apaga também a fatura importada e tudo que pendura nela.

A App Store e a LGPD exigem que excluir a conta leve todos os dados da
pessoa — inclusive descrição e valor de cada compra do cartão. O ORM já
leva ciclos, dias, gastos, vínculos, refresh tokens e assinatura pela
cascata de `User`, mas `credit_card_accounts`, `credit_card_bills` e
`credit_card_transactions` dependem do `ON DELETE CASCADE` do banco. Em
produção o MySQL impõe as FKs; aqui o SQLite só se comporta igual com
`PRAGMA foreign_keys=ON` — sem isso as linhas ficariam órfãs e o teste
passaria sem provar nada.

Cenário: dois usuários, cada um com viagem, dia, gasto, sessão, assinatura
e uma fatura importada por `POST /api/faturas` com duas compras — uma delas
vinculada ao gasto (`AUTO_MATCHED`, criado pela conciliação que a gravação
roda). Depois do `DELETE /auth/conta` de A, nenhuma linha de A pode sobrar;
as de B continuam todas.
"""

import importlib
import sys
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import Session

USER_A = "user-a"
USER_B = "user-b"
INICIO = date(2026, 10, 1)


# ---------------------------------------------------------------- helpers
#
# `_ofx`, `_data`, `_dt`, `_ler` e `_gravar` são o mesmo molde de
# `test_fatura_s2.py`: o envio usa OFX, que não depende do Gemini.


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

    engine = create_engine(f"sqlite:///{tmp_path}/excluir_conta.db")

    # Sem este pragma o SQLite ignora as FKs: o `DELETE FROM users` não
    # dispararia os `ON DELETE CASCADE` e nem daria erro de integridade —
    # o teste mediria um banco mais permissivo que o MySQL de produção.
    @event.listens_for(engine, "connect")
    def _liga_foreign_keys(dbapi_connection, _connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

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


def _plantar_usuario(session, user_id: str, titulo_gasto: str, valor_gasto):
    """Viagem de um dia com um gasto, mais sessão e assinatura."""
    import models

    ciclo = models.Ciclo(id_usuario=user_id, titulo="Viagem")
    session.add(ciclo)
    session.flush()
    dia = models.Dia(
        ciclo_id=ciclo.id,
        data=_dt(INICIO),
        saldo=Decimal("100.00"),
    )
    session.add(dia)
    session.flush()
    gasto = models.Gasto(
        dia_id=dia.id,
        titulo=titulo_gasto,
        valor=Decimal(valor_gasto),
        categoria="ALIMENTACAO",
    )
    session.add(gasto)
    session.add(
        models.RefreshToken(
            user_id=user_id,
            session_id=f"sessao-{user_id}",
            token_hash=f"hash-{user_id}",
            expires_at=datetime(2027, 1, 1),
        )
    )
    session.add(models.Assinatura(user_id=user_id))
    session.commit()
    return ciclo, dia, gasto


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


# ------------------------------------------------------------------ teste


def test_excluir_conta_apaga_fatura_importada_e_vinculos(ambiente):
    import models

    session = ambiente.session
    # Premissa do teste: sem FK ligada, a prova não vale.
    assert session.execute(text("PRAGMA foreign_keys")).scalar() == 1

    # Usuário A: viagem, dia, gasto e fatura com duas compras — a primeira
    # casa com o gasto (mesmo valor, data e texto) e vira AUTO_MATCHED na
    # conciliação que o POST /api/faturas roda.
    _plantar_usuario(session, USER_A, "SUPERMERCADO", "100.00")
    client_a = ambiente.como(USER_A)
    lida_a = _ler(
        client_a,
        _ofx(
            [
                ("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO"),
                ("DEBIT", _data(INICIO + timedelta(days=1)), "-32.40", "UBER"),
            ]
        ),
    )
    detalhe_a = _gravar(client_a, lida_a)
    assert len(detalhe_a["transacoes"]) == 2

    # Usuário B com a mesma coisa: é a testemunha — nada dele pode sair.
    _plantar_usuario(session, USER_B, "PADARIA", "40.00")
    client_b = ambiente.como(USER_B)
    lida_b = _ler(
        client_b,
        _ofx(
            [
                ("DEBIT", _data(INICIO), "-40.00", "PADARIA"),
                ("DEBIT", _data(INICIO + timedelta(days=1)), "-9.90", "CAFE"),
            ]
        ),
    )
    detalhe_b = _gravar(client_b, lida_b)
    assert len(detalhe_b["transacoes"]) == 2

    # Cenário plantado: 1 match de A (AUTO_MATCHED), 1 de B, 2 compras cada.
    matches = {
        t["open_finance_match"]["status"]
        for t in detalhe_a["transacoes"] + detalhe_b["transacoes"]
        if t["open_finance_match"]
    }
    assert matches == {"AUTO_MATCHED"}
    assert session.query(models.ExpenseTransactionMatch).count() == 2

    ids = {}
    for nome, modelo in [
        ("ciclos", models.Ciclo),
        ("contas", models.CreditCardAccount),
        ("faturas", models.CreditCardBill),
        ("compras", models.CreditCardTransaction),
        ("tokens", models.RefreshToken),
        ("assinaturas", models.Assinatura),
    ]:
        coluna_user = (
            models.Ciclo.id_usuario if modelo is models.Ciclo
            else modelo.user_id
        )
        ids[nome] = {
            linha.id
            for linha in session.query(modelo)
            .filter(coluna_user == USER_A)
            .all()
        }
    assert all(ids.values())
    dia_ids_a = {
        d.id
        for d in session.query(models.Dia)
        .filter(models.Dia.ciclo_id.in_(ids["ciclos"]))
        .all()
    }
    gasto_ids_a = {
        g.id
        for g in session.query(models.Gasto)
        .filter(models.Gasto.dia_id.in_(dia_ids_a))
        .all()
    }
    assert dia_ids_a and gasto_ids_a

    # `como()` sobrescreve o override compartilhado: depois do `como(USER_B)`
    # acima, precisa redefinir — senão o DELETE iria para a conta de B.
    resposta = ambiente.como(USER_A).delete("/auth/conta")
    assert resposta.status_code == 204, resposta.text
    # Em produção o commit é do `get_db`; aqui a sessão é compartilhada.
    session.commit()

    # Nada de A pode sobrar — nem por ORM nem por cascata do banco.
    assert session.get(models.User, USER_A) is None
    for modelo, coluna_user in [
        (models.Ciclo, models.Ciclo.id_usuario),
        (models.CreditCardAccount, models.CreditCardAccount.user_id),
        (models.CreditCardBill, models.CreditCardBill.user_id),
        (models.CreditCardTransaction, models.CreditCardTransaction.user_id),
        (models.RefreshToken, models.RefreshToken.user_id),
        (models.Assinatura, models.Assinatura.user_id),
    ]:
        assert (
            session.query(modelo).filter(coluna_user == USER_A).count() == 0
        ), modelo.__tablename__
    assert (
        session.query(models.Dia)
        .filter(models.Dia.id.in_(dia_ids_a))
        .count()
        == 0
    )
    assert (
        session.query(models.Gasto)
        .filter(models.Gasto.id.in_(gasto_ids_a))
        .count()
        == 0
    )
    # Os vínculos não têm user_id: sobram só os de B (1).
    assert session.query(models.ExpenseTransactionMatch).count() == 1
    assert (
        session.query(models.ExpenseTransactionMatch)
        .filter(
            models.ExpenseTransactionMatch.cartao_transacao_id.in_(
                ids["compras"]
            )
        )
        .count()
        == 0
    )

    # E tudo de B continua: usuário, viagem, dia, gasto, sessão, assinatura
    # e a fatura completa (cartão, fatura e as 2 compras).
    assert session.get(models.User, USER_B) is not None
    for modelo, coluna_user, esperado in [
        (models.Ciclo, models.Ciclo.id_usuario, 1),
        (models.CreditCardAccount, models.CreditCardAccount.user_id, 1),
        (models.CreditCardBill, models.CreditCardBill.user_id, 1),
        (models.CreditCardTransaction, models.CreditCardTransaction.user_id, 2),
        (models.RefreshToken, models.RefreshToken.user_id, 1),
        (models.Assinatura, models.Assinatura.user_id, 1),
    ]:
        assert (
            session.query(modelo).filter(coluna_user == USER_B).count()
            == esperado
        ), modelo.__tablename__
    assert session.query(models.Dia).count() == 1
    assert session.query(models.Gasto).count() == 1
    match_b = session.query(models.ExpenseTransactionMatch).one()
    assert match_b.gasto_id == session.query(models.Gasto).one().id
