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

from sqlalchemy.orm import Session

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
    # O dia atual e o novo, os dois com trava (ver `_travar_gasto`).
    assert chamadas == [True, True]
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


# --- Ordem das travas ao apagar/editar um gasto: dia(s) por id → gasto ------
#
# `DELETE /gastos/X` travava o gasto e depois o dia, e `DELETE /dias/{dia de X}`
# trava o dia e depois os gastos: os dois ao mesmo tempo travavam um ao outro.
# Mover A→B junto com B→A também cruzava as travas dos dois dias.


def _espiar_travas(monkeypatch) -> list:
    """Registra, em ordem, as leituras com trava: ("dia", id) e ("gasto", id)."""
    from repositories import dia_repository, gasto_repository

    find_dia = dia_repository.find_dia
    find_gasto_for_update = gasto_repository.find_gasto_for_update
    travas = []

    def espia_dia(db, dia_id, *args, **kwargs):
        if kwargs.get("para_atualizar"):
            travas.append(("dia", dia_id))
        return find_dia(db, dia_id, *args, **kwargs)

    def espia_gasto(db, gasto_id):
        travas.append(("gasto", gasto_id))
        return find_gasto_for_update(db, gasto_id)

    monkeypatch.setattr(dia_repository, "find_dia", espia_dia)
    monkeypatch.setattr(gasto_repository, "find_gasto_for_update", espia_gasto)
    return travas


def _criar_gasto(client, dia_id, client_id, valor) -> int:
    response = client.post(
        f"/dias/{dia_id}/gastos",
        json={
            "client_id": client_id,
            "titulo": "Jantar",
            "valor": valor,
            "categoria": "ALIMENTACAO",
        },
    )
    assert response.status_code == 200
    return response.json()["id"]


def _put_gasto(client, gasto_id, valor, dia_id=None):
    corpo = {"titulo": "Almoço", "valor": valor, "categoria": "ALIMENTACAO"}
    if dia_id is not None:
        corpo["dia_id"] = dia_id
    return client.put(f"/gastos/{gasto_id}", json=corpo)


def _saldos(ambiente, *dia_ids) -> list:
    ambiente.session.commit()
    ambiente.session.expire_all()
    return [ambiente.session.get(models.Dia, i).saldo for i in dia_ids]


def test_delete_do_gasto_trava_o_dia_antes_do_gasto(ambiente, monkeypatch):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, _ = _dias_por_data(client, ciclo["id"])
    gasto_id = dia_1["gastos"][0]["id"]
    travas = _espiar_travas(monkeypatch)

    response = client.delete(f"/gastos/{gasto_id}")

    assert response.status_code == 204
    assert travas == [("dia", dia_1["id"]), ("gasto", gasto_id)]


def test_editar_gasto_sem_mover_trava_o_dia_antes_do_gasto(
    ambiente, monkeypatch  # noqa: F811
):
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, _ = _dias_por_data(client, ciclo["id"])
    gasto_id = dia_1["gastos"][0]["id"]
    travas = _espiar_travas(monkeypatch)

    response = _put_gasto(client, gasto_id, "40.00")

    assert response.status_code == 200
    assert travas == [("dia", dia_1["id"]), ("gasto", gasto_id)]


def test_mover_gasto_trava_os_dois_dias_antes_do_gasto(ambiente, monkeypatch):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    gasto_id = dia_1["gastos"][0]["id"]
    travas = _espiar_travas(monkeypatch)

    response = _put_gasto(client, gasto_id, "30.00", dia_id=dia_2["id"])

    assert response.status_code == 200
    assert travas == [("dia", dia_1["id"]), ("dia", dia_2["id"]), ("gasto", gasto_id)]


def test_mover_para_dia_de_id_menor_trava_em_ordem_crescente(
    ambiente, monkeypatch  # noqa: F811
):
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    assert dia_1["id"] < dia_2["id"]
    gasto_id = _criar_gasto(client, dia_2["id"], "gasto-2", "15.00")
    travas = _espiar_travas(monkeypatch)

    response = _put_gasto(client, gasto_id, "15.00", dia_id=dia_1["id"])

    assert response.status_code == 200
    assert travas == [("dia", dia_1["id"]), ("dia", dia_2["id"]), ("gasto", gasto_id)]


def _mover_em_outra_sessao(engine, gasto_id, de_dia, para_dia, valor):
    """Move o gasto como um `PUT` de outro aparelho faria, com commit."""
    valor = Decimal(valor)
    with Session(engine) as outra:
        outra.query(models.Gasto).filter(models.Gasto.id == gasto_id).update(
            {models.Gasto.dia_id: para_dia}, synchronize_session=False
        )
        outra.query(models.Dia).filter(models.Dia.id == de_dia).update(
            {models.Dia.saldo: models.Dia.saldo + valor}, synchronize_session=False
        )
        outra.query(models.Dia).filter(models.Dia.id == para_dia).update(
            {models.Dia.saldo: models.Dia.saldo - valor}, synchronize_session=False
        )
        outra.commit()


def test_gasto_movido_por_outro_pedido_antes_da_trava_usa_o_dia_novo(
    ambiente, monkeypatch  # noqa: F811
):
    from repositories import gasto_repository

    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    gasto_id = dia_1["gastos"][0]["id"]
    engine = ambiente.session.get_bind()
    # Sem escrita pendente nesta sessão, a outra consegue gravar no SQLite.
    ambiente.session.commit()

    find_gasto = gasto_repository.find_gasto
    leituras = []

    def com_corrida(db, id_):
        gasto = find_gasto(db, id_)
        leituras.append(gasto.dia_id)
        if len(leituras) == 1:
            # Entre a leitura sem trava e a trava, outro aparelho move o gasto.
            _mover_em_outra_sessao(engine, gasto_id, dia_1["id"], dia_2["id"], "30.00")
        return gasto

    monkeypatch.setattr(gasto_repository, "find_gasto", com_corrida)
    travas = _espiar_travas(monkeypatch)

    response = _put_gasto(client, gasto_id, "50.00")

    assert response.status_code == 200
    assert leituras == [dia_1["id"], dia_2["id"]]
    assert travas == [
        ("dia", dia_1["id"]),
        ("gasto", gasto_id),
        ("dia", dia_2["id"]),
        ("gasto", gasto_id),
    ]
    assert ambiente.session.get(models.Gasto, gasto_id).dia_id == dia_2["id"]
    # dia 1 devolveu os 30; dia 2 recebeu 30 e depois a diferença de 20.
    assert _saldos(ambiente, dia_1["id"], dia_2["id"]) == [
        Decimal("100.00"),
        Decimal("50.00"),
    ]
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("50.00")


def test_gasto_que_muda_de_dia_duas_vezes_responde_409(
    ambiente, monkeypatch  # noqa: F811
):
    from repositories import gasto_repository

    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    gasto_id = dia_1["gastos"][0]["id"]
    engine = ambiente.session.get_bind()
    ambiente.session.commit()

    find_gasto = gasto_repository.find_gasto

    def sempre_movendo(db, id_):
        gasto = find_gasto(db, id_)
        destino = dia_2["id"] if gasto.dia_id == dia_1["id"] else dia_1["id"]
        _mover_em_outra_sessao(engine, gasto_id, gasto.dia_id, destino, "30.00")
        return gasto

    monkeypatch.setattr(gasto_repository, "find_gasto", sempre_movendo)

    response = _put_gasto(client, gasto_id, "50.00")

    assert response.status_code == 409
    assert response.json()["error"] == "Gasto alterado ao mesmo tempo, tente de novo"
    # Voltou ao dia 1 (dois movimentos) e nada deste PUT entrou.
    ambiente.session.rollback()
    ambiente.session.expire_all()
    gasto = ambiente.session.get(models.Gasto, gasto_id)
    assert (gasto.dia_id, gasto.valor) == (dia_1["id"], Decimal("30.00"))
    assert _saldos(ambiente, dia_1["id"], dia_2["id"]) == [
        Decimal("70.00"),
        Decimal("100.00"),
    ]
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("30.00")


def test_saldos_e_total_fecham_ao_apagar_editar_e_mover(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _viagem_dois_dias_um_gasto(client)
    dia_1, dia_2 = _dias_por_data(client, ciclo["id"])
    d1, d2 = dia_1["id"], dia_2["id"]
    gasto_1 = dia_1["gastos"][0]["id"]
    gasto_2 = _criar_gasto(client, d2, "gasto-2", "15.00")
    assert _saldos(ambiente, d1, d2) == [Decimal("70.00"), Decimal("85.00")]
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("45.00")

    # Editar o valor: 30 → 40.
    assert _put_gasto(client, gasto_1, "40.00").status_code == 200
    assert _saldos(ambiente, d1, d2) == [Decimal("60.00"), Decimal("85.00")]
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("55.00")

    # Mover do dia 2 (id maior) para o dia 1, mudando o valor: 15 → 25.
    assert _put_gasto(client, gasto_2, "25.00", dia_id=d1).status_code == 200
    assert _saldos(ambiente, d1, d2) == [Decimal("35.00"), Decimal("100.00")]
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("65.00")

    # Apagar.
    assert client.delete(f"/gastos/{gasto_1}").status_code == 204
    assert _saldos(ambiente, d1, d2) == [Decimal("75.00"), Decimal("100.00")]
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("25.00")
