"""Apagar um dia enquanto outro pedido mexe nele.

`DELETE /dias/{id}` descontava do `gasto_total` do ciclo a soma de
`dia.gastos` lida sem trava: dois DELETE ao mesmo tempo (o app repete quando
perde a resposta, ou dois aparelhos) descontavam duas vezes, e um gasto
gravado por outro pedido entre a leitura e o delete ficava fora da soma
(total errado para sempre). Agora o dia é lido com `FOR UPDATE` e os gastos
são somados e apagados a partir de uma leitura com `FOR UPDATE` da tabela;
`POST /dias/{id}/gastos` e `PUT /gastos/{id}` movendo de dia também travam o
dia.

Mesmo molde de `test_editar_diaria_corrida.py`: o gasto "do outro aparelho"
é gravado por outra `Session(engine)` com commit, no meio do pedido.
"""

from decimal import Decimal

import models
from test_editar_diaria import (  # noqa: F401  (`ambiente` é o fixture)
    USER_A,
    _viagem_dois_dias_um_gasto,
    ambiente,
)
from test_editar_diaria_corrida import _gasto_de_outro_aparelho


def _dias_por_data(client, ciclo_id) -> list:
    dias = client.get(f"/ciclos/{ciclo_id}").json()["dias"]
    return sorted(dias, key=lambda d: d["data"])


def _espiar_find_dia(monkeypatch) -> list:
    from repositories import dia_repository

    original = dia_repository.find_dia
    chamadas = []

    def espia(*args, **kwargs):
        chamadas.append(kwargs.get("para_atualizar", False))
        return original(*args, **kwargs)

    monkeypatch.setattr(dia_repository, "find_dia", espia)
    return chamadas


def _gasto_total(ambiente, ciclo_id) -> Decimal:
    # O `get_db` de verdade faz commit no fim do pedido; o do fixture não.
    # Sem o commit, o `expire_all` deixaria os deletes pendentes sem estado.
    ambiente.session.commit()
    return ambiente.session.get(models.Ciclo, ciclo_id).gasto_total


def test_delete_do_dia_le_o_dia_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_id = _dias_por_data(client, ciclo["id"])[0]["id"]
    chamadas = _espiar_find_dia(monkeypatch)

    response = client.delete(f"/dias/{dia_id}")

    assert response.status_code == 204
    assert chamadas == [True]


def test_criar_gasto_le_o_dia_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_id = _dias_por_data(client, ciclo["id"])[1]["id"]
    chamadas = _espiar_find_dia(monkeypatch)

    response = client.post(
        f"/dias/{dia_id}/gastos",
        json={
            "client_id": "gasto-2",
            "titulo": "Jantar",
            "valor": "15.00",
            "categoria": "ALIMENTACAO",
        },
    )

    assert response.status_code == 200
    assert chamadas == [True]


def test_mover_gasto_le_o_dia_novo_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    gasto_id = dia_1["gastos"][0]["id"]
    chamadas = _espiar_find_dia(monkeypatch)

    response = client.put(
        f"/gastos/{gasto_id}",
        json={
            "titulo": "Almoço",
            "valor": "30.00",
            "categoria": "ALIMENTACAO",
            "dia_id": dia_2["id"],
        },
    )

    assert response.status_code == 200
    assert chamadas == [True]
    ambiente.session.expire_all()
    assert ambiente.session.get(models.Gasto, gasto_id).dia_id == dia_2["id"]


def test_gasto_gravado_durante_o_delete_sai_do_total_e_do_banco(
    ambiente, monkeypatch  # noqa: F811
):
    from repositories import dia_repository

    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_id = _dias_por_data(client, ciclo["id"])[0]["id"]
    engine = ambiente.session.get_bind()
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("30.00")

    original = dia_repository.find_dia

    def com_corrida(db, *args, **kwargs):
        dia = original(db, *args, **kwargs)
        # O dia e os gastos dele já estão na sessão do DELETE; o gasto novo
        # chega por outra sessão antes da soma.
        assert len(dia.gastos) == 1
        _gasto_de_outro_aparelho(engine, dia_id, ciclo["id"], "20.00")
        return dia

    monkeypatch.setattr(dia_repository, "find_dia", com_corrida)

    response = client.delete(f"/dias/{dia_id}")

    assert response.status_code == 204
    # Inicial (30 + 20 do outro aparelho = 50) menos todos os gastos do dia.
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("0.00")
    sobras = (
        ambiente.session.query(models.Gasto)
        .filter(models.Gasto.dia_id == dia_id)
        .count()
    )
    assert sobras == 0
    assert ambiente.session.get(models.Dia, dia_id) is None


def test_delete_repetido_desconta_uma_vez_so(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    # Gasto no segundo dia, para o total não chegar a zero e um desconto
    # duplo aparecer como valor errado.
    client.post(
        f"/dias/{dia_2['id']}/gastos",
        json={
            "client_id": "gasto-2",
            "titulo": "Jantar",
            "valor": "15.00",
            "categoria": "ALIMENTACAO",
        },
    )
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("45.00")

    primeiro = client.delete(f"/dias/{dia_1['id']}")
    segundo = client.delete(f"/dias/{dia_1['id']}")

    assert primeiro.status_code == 204
    assert segundo.status_code == 404
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("15.00")
