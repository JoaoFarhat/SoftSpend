"""Mesma fatura gravada duas vezes ao mesmo tempo (`POST /api/faturas`).

Cartão e fatura novos ganham id derivado da chave (`account_id` de
usuário/emissor/final, `bill_id` de cartão/vencimento): na corrida, o segundo
pedido bate no único da coluna no `flush`, `gravar_fatura` faz rollback e
refaz, achando o cartão e a fatura do primeiro — sem nada em dobro.
"""

import importlib
import sys
from datetime import date

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

USER_A = "user-1"
USER_B = "user-2"
VENCIMENTO = date(2026, 10, 20)


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
    from dependencies import get_current_user_id
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/fatura_corrida.db")
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
    app.dependency_overrides[get_current_user_id] = lambda: USER_A
    try:
        yield TestClient(app), session, engine
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


def _corpo() -> dict:
    return {
        "emissor": "Banco Teste",
        "final_cartao": "1234",
        "vencimento": VENCIMENTO.isoformat(),
        "total_fatura": "150.00",
        "compras": [
            {
                "indice": 0,
                "data": "2026-10-02",
                "descricao": "SUPERMERCADO X",
                "valor": "100.00",
            },
            {
                "indice": 1,
                "data": "2026-10-03",
                "descricao": "PADARIA Y",
                "valor": "50.00",
            },
        ],
    }


def _gravar_por_outra_sessao(engine) -> None:
    """O "primeiro pedido": grava e confirma por uma sessão própria."""
    from dtos.fatura import FaturaLida
    from services import fatura_service

    outra = Session(engine)
    try:
        fatura_service.gravar_fatura(
            outra, USER_A, FaturaLida.model_validate(_corpo())
        )
        outra.commit()
    finally:
        outra.close()


def _none_na_primeira(monkeypatch, nome: str) -> list:
    """Faz `fatura_service.<nome>` devolver None só na 1ª chamada — como se
    a busca tivesse rodado antes do commit do outro pedido."""
    from services import fatura_service

    original = getattr(fatura_service, nome)
    chamadas = []

    def falsa(*args, **kwargs):
        chamadas.append(1)
        if len(chamadas) == 1:
            return None
        return original(*args, **kwargs)

    monkeypatch.setattr(fatura_service, nome, falsa)
    return chamadas


def _contagens(session) -> tuple[int, int, list[str]]:
    import models

    session.expire_all()
    ids = [
        t.transaction_id
        for t in session.query(models.CreditCardTransaction).all()
    ]
    return (
        session.query(models.CreditCardAccount).count(),
        session.query(models.CreditCardBill).count(),
        ids,
    )


# ---------------------------------------------------------- ids derivados


def test_account_id_derivado_da_chave():
    from services import fatura_service

    base = fatura_service._account_id_cartao(USER_A, "Banco Teste", "1234")
    assert base == fatura_service._account_id_cartao(
        USER_A, "Banco Teste", "1234"
    )
    assert base.startswith("fatura:") and len(base) == 64
    assert base != fatura_service._account_id_cartao(
        USER_B, "Banco Teste", "1234"
    )
    assert base != fatura_service._account_id_cartao(
        USER_A, "Banco Teste", "9999"
    )
    assert base != fatura_service._account_id_cartao(
        USER_A, "Outro Banco", "1234"
    )


def test_bill_id_derivado_do_cartao_e_vencimento():
    from services import fatura_service

    bill = fatura_service._bill_id_fatura("fatura:abc", VENCIMENTO)
    assert bill == fatura_service._bill_id_fatura("fatura:abc", VENCIMENTO)
    assert bill.startswith("fatura:") and len(bill) == 64
    assert bill != fatura_service._bill_id_fatura("fatura:xyz", VENCIMENTO)
    assert bill != fatura_service._bill_id_fatura(
        "fatura:abc", date(2026, 11, 20)
    )


def test_cartao_novo_grava_ids_derivados(ambiente):
    import models
    from services import fatura_service

    client, session, _ = ambiente
    resposta = client.post("/api/faturas", json=_corpo())
    assert resposta.status_code == 200, resposta.text

    cartao = session.query(models.CreditCardAccount).one()
    fatura = session.query(models.CreditCardBill).one()
    assert cartao.account_id == fatura_service._account_id_cartao(
        USER_A, "Banco Teste", "1234"
    )
    assert fatura.bill_id == fatura_service._bill_id_fatura(
        cartao.account_id, VENCIMENTO
    )


# ---------------------------------------------------------------- corrida


@pytest.mark.parametrize("busca", ["_buscar_cartao", "_buscar_fatura"])
def test_corrida_nao_duplica_cartao_fatura_nem_compras(
    ambiente, monkeypatch, busca
):
    client, session, engine = ambiente
    _gravar_por_outra_sessao(engine)
    antes = _contagens(session)
    assert antes[:2] == (1, 1) and len(antes[2]) == 2

    chamadas = _none_na_primeira(monkeypatch, busca)
    resposta = client.post("/api/faturas", json=_corpo())

    assert resposta.status_code == 200, resposta.text
    assert len(chamadas) == 2  # a 1ª bateu no único; o refaz achou
    cartoes, faturas, ids = _contagens(session)
    assert (cartoes, faturas) == (1, 1)
    assert sorted(ids) == sorted(antes[2])
    assert len(set(ids)) == len(ids) == 2


def test_cartao_antigo_com_uuid_continua_reusado(ambiente):
    import models

    client, session, _ = ambiente
    antigo = models.CreditCardAccount(
        user_id=USER_A,
        conexao_id=None,
        origem="FATURA",
        account_id="fatura:5b0e6c1e-7d55-4a43-9a4c-3f1f3d1c2b9a",
        institution_name="Banco Teste",
        number_last4="1234",
        name="Banco Teste •••• 1234",
        currency_code="BRL",
    )
    session.add(antigo)
    session.commit()

    resposta = client.post("/api/faturas", json=_corpo())
    assert resposta.status_code == 200, resposta.text

    cartoes = session.query(models.CreditCardAccount).all()
    assert len(cartoes) == 1
    assert cartoes[0].account_id == "fatura:5b0e6c1e-7d55-4a43-9a4c-3f1f3d1c2b9a"
    fatura = session.query(models.CreditCardBill).one()
    assert fatura.cartao_id == antigo.id
