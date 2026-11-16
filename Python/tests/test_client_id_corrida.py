"""Reenvio com o mesmo `client_id` enquanto o primeiro pedido ainda grava.

Na corrida real, o segundo pedido não acha o registro (o primeiro ainda não
gravou) e o insert esbarra no unique. Aqui a corrida é simulada fazendo o
`find_by_client_id` do repositório devolver `None` só na primeira chamada:
o insert esbarra no unique, o savepoint é desfeito e a releitura acha o
registro do primeiro pedido. Antes disso a rota respondia 500.
"""

import pytest

import models
from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    _ciclo_payload,
    _dia_payload,
    _gasto_payload,
    ambiente,
)


def _corrida(monkeypatch, repositorio):
    """Primeira chamada de `find_by_client_id` não acha nada; as outras leem."""
    original = repositorio.find_by_client_id
    chamadas = []

    def falso(*args, **kwargs):
        chamadas.append(args)
        if len(chamadas) == 1:
            return None
        return original(*args, **kwargs)

    monkeypatch.setattr(repositorio, "find_by_client_id", falso)
    return chamadas


@pytest.fixture
def criados(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = client.post("/ciclos", json=_ciclo_payload()).json()
    dia = client.post(f"/ciclos/{ciclo['id']}/dias", json=_dia_payload()).json()
    gasto = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload(valor="30.00")
    ).json()
    return client, ciclo, dia, gasto


def _confere_valores(ambiente, client, ciclo):  # noqa: F811
    lido = client.get(f"/ciclos/{ciclo['id']}").json()
    assert lido["gasto_total"] == 30.00
    assert len(lido["dias"]) == 1
    assert lido["dias"][0]["saldo"] == 70.00
    assert len(lido["dias"][0]["gastos"]) == 1
    sessao = ambiente.session
    assert sessao.query(models.Ciclo).count() == 1
    assert sessao.query(models.Dia).count() == 1
    assert sessao.query(models.Gasto).count() == 1


def test_reenvio_ciclo_durante_gravacao_devolve_o_existente(
    ambiente, criados, monkeypatch  # noqa: F811
):
    from repositories import ciclo_repository

    client, ciclo, _, _ = criados
    chamadas = _corrida(monkeypatch, ciclo_repository)

    resposta = client.post("/ciclos", json=_ciclo_payload(titulo="Outro"))

    assert resposta.status_code in (200, 201)
    assert resposta.json()["id"] == ciclo["id"]
    assert len(chamadas) == 2  # a busca que perdeu a corrida + a releitura
    _confere_valores(ambiente, client, ciclo)


def test_reenvio_dia_durante_gravacao_devolve_o_existente(
    ambiente, criados, monkeypatch  # noqa: F811
):
    from repositories import dia_repository

    client, ciclo, dia, _ = criados
    chamadas = _corrida(monkeypatch, dia_repository)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload(data="2026-11-03T00:00:00Z"),
    )

    assert resposta.status_code in (200, 201)
    assert resposta.json()["id"] == dia["id"]
    assert len(chamadas) == 2
    _confere_valores(ambiente, client, ciclo)


def test_reenvio_gasto_durante_gravacao_nao_conta_o_dinheiro_duas_vezes(
    ambiente, criados, monkeypatch  # noqa: F811
):
    from repositories import gasto_repository
    from services import open_finance_reconciliation_service

    client, ciclo, dia, gasto = criados
    chamadas = _corrida(monkeypatch, gasto_repository)
    conciliados = []
    original = open_finance_reconciliation_service.conciliar_gasto
    monkeypatch.setattr(
        open_finance_reconciliation_service,
        "conciliar_gasto",
        lambda db, g, user_id: (conciliados.append(g.id), original(db, g, user_id))[1],
    )

    resposta = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload(valor="30.00")
    )

    assert resposta.status_code in (200, 201)
    assert resposta.json()["id"] == gasto["id"]
    assert len(chamadas) == 2
    # Mesmo caminho do reenvio comum: concilia o gasto existente.
    assert conciliados == [gasto["id"]]
    _confere_valores(ambiente, client, ciclo)


def test_integrity_error_sem_registro_para_reler_e_relancado(
    ambiente, criados, monkeypatch  # noqa: F811
):
    """Se a releitura não acha nada, o erro não é engolido."""
    from sqlalchemy.exc import IntegrityError

    from repositories import ciclo_repository

    client, _, _, _ = criados
    monkeypatch.setattr(ciclo_repository, "find_by_client_id", lambda *a, **k: None)

    with pytest.raises(IntegrityError):
        client.post("/ciclos", json=_ciclo_payload())
