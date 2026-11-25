"""Editar a diária enquanto outro aparelho lança um gasto no mesmo dia.

`PUT /ciclos/{id}` mudando a diária ajusta o `saldo` de cada dia com um
`UPDATE` relativo no banco (`saldo = saldo + (nova - antiga)`). Antes, o
saldo era gravado como valor absoluto (`nova_diaria - soma dos gastos`
carregados na sessão): um gasto gravado por outra sessão entre a leitura e o
commit (o `criar_gasto` faz `saldo = saldo - valor`) era sobrescrito e o
saldo do dia ficava maior para sempre.

A corrida é simulada trocando `ciclo_repository.update_ciclo` por um
embrulho que, depois de o ciclo já ter sido carregado pelo serviço e antes
de a edição gravar, grava um gasto por outra sessão (com commit).
"""

from decimal import Decimal

from sqlalchemy.orm import Session

import models
from test_editar_diaria import (  # noqa: F401  (`ambiente` é o fixture)
    USER_A,
    USER_B,
    _ciclo_payload,
    _saldos_por_data,
    _viagem_dois_dias_um_gasto,
    ambiente,
)


def _gasto_de_outro_aparelho(engine, dia_id: int, ciclo_id: int, valor: str):
    """Grava um gasto como o `criar_gasto` faz: insert + descontos relativos."""
    valor = Decimal(valor)
    with Session(engine) as outra:
        outra.add(
            models.Gasto(
                client_id="gasto-outro-aparelho",
                dia_id=dia_id,
                titulo="Táxi",
                valor=valor,
                categoria="TRANSPORTE",
            )
        )
        outra.query(models.Dia).filter(models.Dia.id == dia_id).update(
            {models.Dia.saldo: models.Dia.saldo - valor},
            synchronize_session=False,
        )
        outra.query(models.Ciclo).filter(models.Ciclo.id == ciclo_id).update(
            {models.Ciclo.gasto_total: models.Ciclo.gasto_total + valor},
            synchronize_session=False,
        )
        outra.commit()


def _primeiro_dia_id(client, ciclo_id) -> int:
    dias = client.get(f"/ciclos/{ciclo_id}").json()["dias"]
    return sorted(dias, key=lambda d: d["data"])[0]["id"]


def test_gasto_gravado_durante_a_edicao_continua_descontado(
    ambiente, monkeypatch  # noqa: F811
):
    from repositories import ciclo_repository

    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_id = _primeiro_dia_id(client, ciclo["id"])
    engine = ambiente.session.get_bind()

    original = ciclo_repository.update_ciclo

    def com_corrida(db, ciclo_carregado, ciclo_request):
        # O ciclo, os dias e os gastos já estão na sessão do PUT; o gasto
        # novo chega por outra sessão antes de a edição gravar.
        _gasto_de_outro_aparelho(engine, dia_id, ciclo["id"], "20.00")
        return original(db, ciclo_carregado, ciclo_request)

    monkeypatch.setattr(ciclo_repository, "update_ciclo", com_corrida)

    response = client.put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(diaria="150.00")
    )
    assert response.status_code == 200

    ambiente.session.expire_all()
    # Dia 1: 150 - (30 antigo + 20 novo); dia 2 sem gastos.
    assert _saldos_por_data(client, ciclo["id"]) == [100.00, 150.00]
    dia = ambiente.session.get(models.Dia, dia_id)
    assert dia.saldo == Decimal("100.00")


def test_resposta_do_put_traz_o_saldo_novo_de_cada_dia(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)

    response = client.put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(diaria="150.00")
    )

    assert response.status_code == 200
    saldos = [
        dia["saldo"]
        for dia in sorted(response.json()["dias"], key=lambda d: d["data"])
    ]
    assert saldos == [120.00, 150.00]


def test_update_ciclo_le_o_ciclo_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    from repositories import ciclo_repository

    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)

    original = ciclo_repository.get_user_ciclo_by_id
    chamadas = []

    def espia(*args, **kwargs):
        chamadas.append(kwargs.get("para_atualizar", False))
        return original(*args, **kwargs)

    monkeypatch.setattr(ciclo_repository, "get_user_ciclo_by_id", espia)

    response = client.put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(diaria="150.00")
    )

    assert response.status_code == 200
    assert chamadas == [True]


def test_criar_dia_le_o_ciclo_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    """POST /dias: o dia novo nasce com a `diaria` lida sob a trava do ciclo."""
    from repositories import ciclo_repository

    client = ambiente.como(USER_A)
    ciclo = client.post("/ciclos", json=_ciclo_payload()).json()

    original = ciclo_repository.get_user_ciclo_by_id
    chamadas = []

    def espia(*args, **kwargs):
        chamadas.append(kwargs.get("para_atualizar", False))
        return original(*args, **kwargs)

    monkeypatch.setattr(ciclo_repository, "get_user_ciclo_by_id", espia)

    response = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={"client_id": "dia-1", "data": "2026-11-01T00:00:00Z"},
    )

    assert response.status_code == 200
    assert chamadas == [True]


def test_criar_dias_lote_le_o_ciclo_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    """POST /dias/lote: a mesma trava vale para o lote inteiro."""
    from repositories import ciclo_repository

    client = ambiente.como(USER_A)
    ciclo = client.post("/ciclos", json=_ciclo_payload()).json()

    original = ciclo_repository.get_user_ciclo_by_id
    chamadas = []

    def espia(*args, **kwargs):
        chamadas.append(kwargs.get("para_atualizar", False))
        return original(*args, **kwargs)

    monkeypatch.setattr(ciclo_repository, "get_user_ciclo_by_id", espia)

    response = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            {"client_id": "dia-1", "data": "2026-11-01T00:00:00Z"},
            {"client_id": "dia-2", "data": "2026-11-02T00:00:00Z"},
        ],
    )

    assert response.status_code == 200
    assert chamadas == [True]


def test_editar_ciclo_de_outro_usuario_continua_404(ambiente):  # noqa: F811
    ciclo = _viagem_dois_dias_um_gasto(ambiente.como(USER_A))

    response = ambiente.como(USER_B).put(
        f"/ciclos/{ciclo['id']}", json=_ciclo_payload(diaria="150.00")
    )

    assert response.status_code == 404
    ambiente.session.expire_all()
    assert _saldos_por_data(ambiente.como(USER_A), ciclo["id"]) == [70.00, 100.00]
