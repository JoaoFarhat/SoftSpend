"""`client_id` repetido dentro do mesmo `POST /ciclos/{id}/dias/lote`.

Antes, dois itens novos com o mesmo `client_id` esbarravam no unique
`uix_dia_client_id_ciclo` na gravação: o savepoint desfazia os dois, a
releitura não achava nada e o erro virava 500 — e um único item repetido
fazia o app marcar a viagem inteira como falha, com espera. Agora o item
repetido reusa o dia montado para o primeiro e a resposta mantém a ordem
pedida, com o mesmo dia nas duas posições.
"""

from decimal import Decimal

import models
from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    _ciclo_payload,
    _dia_payload,
    ambiente,
)


def _criar_ciclo(client) -> dict:
    resposta = client.post("/ciclos", json=_ciclo_payload())
    assert resposta.status_code == 200
    return resposta.json()


def test_lote_com_client_id_repetido_cria_um_dia_so(ambiente):  # noqa: F811
    """Lote `[X, Y, X]` novo: 3 itens na resposta, o 1º e o 3º com o mesmo
    `id`, e só 2 dias no banco."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-x", "2026-11-01T00:00:00Z"),
            _dia_payload("dia-y", "2026-11-02T00:00:00Z"),
            _dia_payload("dia-x", "2026-11-03T00:00:00Z"),
        ],
    )

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert len(corpo) == 3
    assert corpo[0]["id"] == corpo[2]["id"]
    assert corpo[0]["id"] != corpo[1]["id"]

    dias = ambiente.session.query(models.Dia).all()
    assert len(dias) == 2
    assert all(dia.saldo == Decimal("100.00") for dia in dias)


def test_reenvio_do_lote_com_repetido_devolve_os_mesmos_dias(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    lote = [
        _dia_payload("dia-x", "2026-11-01T00:00:00Z"),
        _dia_payload("dia-y", "2026-11-02T00:00:00Z"),
        _dia_payload("dia-x", "2026-11-03T00:00:00Z"),
    ]

    ids = [d["id"] for d in client.post(
        f"/ciclos/{ciclo['id']}/dias/lote", json=lote
    ).json()]

    resposta = client.post(f"/ciclos/{ciclo['id']}/dias/lote", json=lote)

    assert resposta.status_code == 200
    assert [d["id"] for d in resposta.json()] == ids
    assert ambiente.session.query(models.Dia).count() == 2


def test_lote_repete_client_id_ja_gravado_devolve_o_existente(ambiente):  # noqa: F811
    """`X` já gravado antes e repetido duas vezes no lote: o dia existente
    volta nas duas posições."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload("dia-x", "2026-11-01T00:00:00Z"),
    ).json()

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-x", "2026-11-01T00:00:00Z"),
            _dia_payload("dia-x", "2026-11-02T00:00:00Z"),
        ],
    )

    assert resposta.status_code == 200
    assert [d["id"] for d in resposta.json()] == [dia["id"], dia["id"]]
    assert ambiente.session.query(models.Dia).count() == 1
