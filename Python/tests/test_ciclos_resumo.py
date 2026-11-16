"""Testes do GET /usuario/ciclos/resumo.

Mesmo padrão de `test_core_api.py`: SQLite em `tmp_path`,
`app.dependency_overrides` para `get_db` e `get_current_user_id`. A diferença
é que `get_db` abre uma sessão nova por requisição, como em produção: a
serialização do `CicloResponse` acontece com a sessão ainda aberta, então o
teste de N+1 mede também os SELECTs disparados pelo lazy load na hora de
montar a resposta.
"""

import importlib
import sys
from contextlib import contextmanager
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session

USER_A = "user-a"
USER_B = "user-b"


def _app(monkeypatch):
    """Reimporta `main` com env mínimo, como em `test_core_api._app`."""
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    return importlib.import_module("main").app


class _Ambiente:
    def __init__(self, app, engine):
        self.app = app
        self.engine = engine
        # `None` fora de `medir_selects`: os statements das requisições entre
        # uma medição e outra não podem cair na medição anterior.
        self.selects = None

        def contar(conn, cursor, statement, parameters, context, executemany):
            if self.selects is not None and statement.lstrip().upper().startswith(
                "SELECT"
            ):
                self.selects.append(statement)

        self._contar = contar
        event.listen(engine, "before_cursor_execute", contar)

    def como(self, user_id: str, **kwargs) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app, **kwargs)

    @contextmanager
    def medir_selects(self):
        self.selects = []
        try:
            yield self.selects
        finally:
            self.selects = None

    def fechar(self):
        event.remove(self.engine, "before_cursor_execute", self._contar)


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    import models

    app = _app(monkeypatch)
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/resumo.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(
                id=USER_A,
                nome="A",
                username="user_a",
                email="a@example.com",
                senha_hash="hash",
            ),
            models.User(
                id=USER_B,
                nome="B",
                username="user_b",
                email="b@example.com",
                senha_hash="hash",
            ),
        ]
    )
    session.commit()
    session.close()

    # Uma sessão por requisição, igual ao `get_db` real: sem commit o POST não
    # aparece para o GET seguinte, e cada GET parte do identity map vazio.
    def override_db():
        db = Session(engine)
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_db
    env = _Ambiente(app, engine)
    try:
        yield env
    finally:
        env.fechar()
        app.dependency_overrides.clear()
        engine.dispose()


_seq = 0


def _proximo(prefixo: str) -> str:
    global _seq
    _seq += 1
    return f"{prefixo}-{_seq}"


def _criar_ciclo(client, titulo: str) -> dict:
    response = client.post(
        "/ciclos",
        json={
            "client_id": _proximo("ciclo"),
            "valor_total": "700.00",
            "periodo": "01/11/2026 a 07/11/2026",
            "diaria": "100.00",
            "titulo": titulo,
        },
    )
    assert response.status_code == 200
    return response.json()


def _criar_ciclo_com_dias_e_gastos(
    client, titulo: str, dias: int = 3, gastos: int = 2
) -> dict:
    ciclo = _criar_ciclo(client, titulo)
    for i in range(dias):
        dia = client.post(
            f"/ciclos/{ciclo['id']}/dias",
            json={
                "client_id": _proximo("dia"),
                "data": f"2026-11-{i + 1:02d}T00:00:00Z",
            },
        ).json()
        for j in range(gastos):
            response = client.post(
                f"/dias/{dia['id']}/gastos",
                json={
                    "client_id": _proximo("gasto"),
                    "titulo": f"Gasto {i}-{j}",
                    "valor": "10.00",
                    "categoria": "ALIMENTACAO",
                },
            )
            assert response.status_code == 200
    return ciclo


def _criar_match(ambiente, ciclo_id: int):
    """Cria 1 match de Open Finance num gasto da viagem.

    Sem match, o último nível do `selectinload` do resumo
    (`ExpenseTransactionMatch.transacao`) nunca carrega nada e o teste de
    contagem de SELECTs passaria mesmo se aquele `selectinload` sumisse —
    cada match faria um lazy load da transação na serialização.
    """
    import models

    session = Session(ambiente.engine)
    try:
        gasto = (
            session.query(models.Gasto)
            .join(models.Dia)
            .filter(models.Dia.ciclo_id == ciclo_id)
            .first()
        )
        cartao = models.CreditCardAccount(
            user_id=USER_A, account_id=_proximo("acc"), name="Cartão"
        )
        session.add(cartao)
        session.flush()
        transacao = models.CreditCardTransaction(
            cartao_id=cartao.id,
            user_id=USER_A,
            transaction_id=_proximo("tx"),
            description="COMPRA",
            amount=Decimal("10.00"),
        )
        session.add(transacao)
        session.flush()
        session.add(
            models.ExpenseTransactionMatch(
                gasto_id=gasto.id,
                cartao_transacao_id=transacao.id,
                status="REVIEW",
                score=70,
                method="RULES",
            )
        )
        session.commit()
    finally:
        session.close()


def test_resumo_ordem_estrutura_paginacao_e_isolamento(ambiente):
    # `como` troca o override do app inteiro, então a viagem do usuário B é
    # criada antes de virar A — cliente criado antes não guarda o usuário.
    client_b = ambiente.como(USER_B)
    de_outro = _criar_ciclo_com_dias_e_gastos(client_b, "Viagem de outro usuario")

    client_a = ambiente.como(USER_A)
    antigo = _criar_ciclo_com_dias_e_gastos(client_a, "Viagem antiga")
    meio = _criar_ciclo_com_dias_e_gastos(client_a, "Viagem do meio")
    novo = _criar_ciclo_com_dias_e_gastos(client_a, "Viagem nova")

    response = client_a.get("/usuario/ciclos/resumo")
    assert response.status_code == 200
    ciclos = response.json()

    # Mais nova primeiro (id desc) e nada do outro usuário.
    assert [c["id"] for c in ciclos] == [novo["id"], meio["id"], antigo["id"]]
    assert de_outro["id"] not in [c["id"] for c in ciclos]
    for ciclo in ciclos:
        assert len(ciclo["dias"]) == 3
        for dia in ciclo["dias"]:
            assert len(dia["gastos"]) == 2
            for gasto in dia["gastos"]:
                assert gasto["open_finance_status"] == "PENDENTE"
                assert gasto["open_finance_match"] is None

    pagina = client_a.get("/usuario/ciclos/resumo", params={"skip": 1, "limit": 1})
    assert [c["id"] for c in pagina.json()] == [meio["id"]]
    pagina = client_a.get("/usuario/ciclos/resumo", params={"limit": 2})
    assert [c["id"] for c in pagina.json()] == [novo["id"], meio["id"]]


def test_resumo_numero_de_consultas_nao_cresce_com_o_tamanho(ambiente):
    client = ambiente.como(USER_A)

    _criar_match(ambiente, _criar_ciclo_com_dias_e_gastos(client, "Viagem 1")["id"])
    with ambiente.medir_selects() as selects_1:
        resposta_1 = client.get("/usuario/ciclos/resumo")
        assert resposta_1.status_code == 200

    for titulo in ("Viagem 2", "Viagem 3"):
        ciclo = _criar_ciclo_com_dias_e_gastos(client, titulo)
        _criar_match(ambiente, ciclo["id"])
    with ambiente.medir_selects() as selects_3:
        resposta_3 = client.get("/usuario/ciclos/resumo")
        assert resposta_3.status_code == 200

    # Os matches saem preenchidos na resposta (a serialização lê a transação
    # do match, o nível mais fundo do selectinload).
    for resposta in (resposta_1, resposta_3):
        matches = [
            gasto["open_finance_match"]
            for ciclo in resposta.json()
            for dia in ciclo["dias"]
            for gasto in dia["gastos"]
            if gasto["open_finance_match"] is not None
        ]
        assert matches and all(
            match["provider_transaction_id"] is not None for match in matches
        )

    # 1 viagem ou 3 viagens de 3 dias e 2 gastos cada, com 1 match por
    # viagem: o resumo tem que sair com o mesmo número de SELECTs (um por
    # nível carregado), sem N+1.
    assert len(selects_3) == len(selects_1)
