"""Reenvio com o mesmo `client_id` enquanto o primeiro pedido ainda grava.

Na corrida real, o segundo pedido não acha o registro (o primeiro ainda não
gravou) e o insert esbarra no unique. Aqui a corrida é simulada fazendo o
`find_by_client_id` do repositório devolver `None` só na primeira chamada:
o insert esbarra no unique, o savepoint é desfeito e a releitura acha o
registro do primeiro pedido. Antes disso a rota respondia 500.
"""

from types import SimpleNamespace

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
        chamadas.append(kwargs.get("para_atualizar", False))
        if len(chamadas) == 1:
            return None
        return original(*args, **kwargs)

    monkeypatch.setattr(repositorio, "find_by_client_id", falso)
    return chamadas


def _corrida_lote(monkeypatch, enxerga=()):
    """Primeira leitura do ciclo não enxerga os dias que o outro pedido gravou.

    O lote faz dedup pela coleção `ciclo.dias`, não por `find_by_client_id`:
    a foto tirada antes do commit do primeiro pedido só contém os dias
    gravados por pedidos anteriores (os `client_id` em `enxerga`).
    """
    from repositories import ciclo_repository

    original = ciclo_repository.get_user_ciclo_by_id
    visiveis = set(enxerga)
    chamadas = []

    def falso(*args, **kwargs):
        ciclo = original(*args, **kwargs)
        chamadas.append(ciclo)
        if len(chamadas) == 1 and ciclo is not None:
            return SimpleNamespace(
                diaria=ciclo.diaria,
                dias=[d for d in ciclo.dias if d.client_id in visiveis],
            )
        return ciclo

    monkeypatch.setattr(ciclo_repository, "get_user_ciclo_by_id", falso)
    return chamadas


def _espia_releitura(monkeypatch):
    """Registra com que bloqueio o `find_by_client_id` de dias é chamado."""
    from repositories import dia_repository

    original = dia_repository.find_by_client_id
    chamadas = []

    def falso(*args, **kwargs):
        chamadas.append(kwargs.get("para_atualizar", False))
        return original(*args, **kwargs)

    monkeypatch.setattr(dia_repository, "find_by_client_id", falso)
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
    # A busca que perdeu a corrida (comum) + a releitura com bloqueio, que no
    # MySQL (REPEATABLE READ) é a única que vê a linha do outro pedido.
    assert chamadas == [False, True]
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
    assert chamadas == [False, True]
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
    assert chamadas == [False, True]
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


def test_reenvio_dias_em_lote_durante_gravacao_devolve_os_existentes(
    ambiente, criados, monkeypatch  # noqa: F811
):
    client, ciclo, dia, _ = criados

    primeiro = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-lote-1", "2026-11-02T00:00:00Z"),
            _dia_payload("dia-lote-2", "2026-11-03T00:00:00Z"),
        ],
    )
    ids = [d["id"] for d in primeiro.json()]

    # O reenvio chega com a foto anterior ao commit do primeiro pedido: a
    # dedup não enxerga os dias do lote, só o dia mais antigo do ciclo.
    _corrida_lote(monkeypatch, enxerga={dia["client_id"]})
    releituras = _espia_releitura(monkeypatch)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-lote-1", "2026-11-02T00:00:00Z"),
            _dia_payload("dia-lote-2", "2026-11-03T00:00:00Z"),
        ],
    )

    assert resposta.status_code in (200, 201)
    assert [d["id"] for d in resposta.json()] == ids
    # Releitura dos dois `client_id` pedidos, sempre com bloqueio (a única
    # leitura que vê a linha do outro pedido no MySQL REPEATABLE READ).
    assert releituras == [True, True]
    assert ambiente.session.query(models.Dia).count() == 3


def test_dias_em_lote_misto_cria_so_o_novo(ambiente, criados):  # noqa: F811
    """Lote misto sem corrida: o dia já gravado volta da dedup e só o novo
    é inserido."""
    client, ciclo, dia, _ = criados

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload(dia["client_id"], "2026-11-02T00:00:00Z"),
            _dia_payload("dia-novo", "2026-11-03T00:00:00Z"),
        ],
    )

    assert resposta.status_code in (200, 201)
    corpo = resposta.json()
    assert corpo[0]["id"] == dia["id"]
    assert corpo[1]["client_id"] == "dia-novo"
    assert ambiente.session.query(models.Dia).count() == 2


def test_dias_em_lote_misto_durante_gravacao_devolve_os_existentes(
    ambiente, criados, monkeypatch  # noqa: F811
):
    """Lote misto na corrida: a dedup resolve o dia mais antigo; o novo,
    gravado pelo pedido concorrente, volta da releitura — sem duplicar."""
    client, ciclo, dia, _ = criados

    gravado = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[_dia_payload("dia-novo", "2026-11-03T00:00:00Z")],
    ).json()[0]

    # A foto do reenvio é anterior ao commit do primeiro pedido: enxerga o
    # dia mais antigo, mas não o "dia-novo".
    _corrida_lote(monkeypatch, enxerga={dia["client_id"]})
    releituras = _espia_releitura(monkeypatch)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload(dia["client_id"], "2026-11-01T00:00:00Z"),
            _dia_payload("dia-novo", "2026-11-03T00:00:00Z"),
        ],
    )

    assert resposta.status_code in (200, 201)
    assert [d["id"] for d in resposta.json()] == [dia["id"], gravado["id"]]
    assert releituras == [True, True]
    # O novo existe uma única vez: nenhum dos dois foi duplicado.
    assert ambiente.session.query(models.Dia).count() == 2


def test_integrity_error_em_lote_sem_dia_para_reler_e_relancado(
    ambiente, criados, monkeypatch  # noqa: F811
):
    """Reenvio que o primeiro pedido só gravou em parte: um `client_id` do
    lote não existe no banco e o erro não é engolido."""
    from sqlalchemy.exc import IntegrityError

    client, ciclo, dia, _ = criados

    _corrida_lote(monkeypatch)

    with pytest.raises(IntegrityError):
        client.post(
            f"/ciclos/{ciclo['id']}/dias/lote",
            json=[
                _dia_payload(dia["client_id"], "2026-11-01T00:00:00Z"),
                _dia_payload("dia-nunca-gravado", "2026-11-02T00:00:00Z"),
            ],
        )


def test_integrity_error_em_lote_com_pedido_sem_client_id_relanca(
    ambiente, criados, monkeypatch  # noqa: F811
):
    """Pedido sem `client_id` não pode ser relido: o erro propaga."""
    from sqlalchemy.exc import IntegrityError

    client, ciclo, dia, _ = criados

    _corrida_lote(monkeypatch)

    with pytest.raises(IntegrityError):
        client.post(
            f"/ciclos/{ciclo['id']}/dias/lote",
            json=[
                _dia_payload(dia["client_id"], "2026-11-01T00:00:00Z"),
                {"data": "2026-11-02T00:00:00Z"},
            ],
        )
