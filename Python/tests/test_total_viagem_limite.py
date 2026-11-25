"""Teto do `gasto_total` da viagem (Numeric(10, 2) = 99.999.999,99).

Sem a conferência do `gasto_service`, um gasto que levasse o total da viagem
além do teto da coluna fazia o MySQL recusar o UPDATE de
`incrementar_gasto_total` e o `POST /dias/{id}/gastos` (ou o
`PUT /gastos/{id}`) caía com 500 — erro que o app repete sem fim. Agora a
rota responde 422 com `error = "total_da_viagem_acima_do_limite"` e nada é
gravado. O reenvio com o mesmo `client_id` continua devolvendo o gasto já
gravado, mesmo com o total no teto.
"""

from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    _ciclo_payload,
    _dia_payload,
    _gasto_payload,
    ambiente,
)

DATAS = [
    "2026-11-01T00:00:00Z",
    "2026-11-02T00:00:00Z",
]


def _viagem(client, client_id):
    """Viagem com `valor_total` e `diaria` no teto da coluna Numeric(10, 2):
    o único limite que pode estourar é o `gasto_total`."""
    response = client.post(
        "/ciclos",
        json=_ciclo_payload(
            client_id=client_id,
            valor_total="99999999.99",
            diaria="99999999.99",
        ),
    )
    assert response.status_code == 200
    ciclo = response.json()

    response = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload(f"{client_id}-dia-{i + 1}", data)
            for i, data in enumerate(DATAS)
        ],
    )
    assert response.status_code == 200
    return ciclo, response.json()


def _gasto(client, dia_id, client_id, valor):
    response = client.post(
        f"/dias/{dia_id}/gastos",
        json=_gasto_payload(client_id=client_id, valor=valor),
    )
    assert response.status_code == 200
    return response.json()


def _dia_lido(corpo, dia_id):
    return next(d for d in corpo["dias"] if d["id"] == dia_id)


def test_segundo_gasto_grande_da_422_e_nada_muda(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-teto")
    primeiro = _gasto(client, dias[0]["id"], "gasto-60m-a", "60000000.00")

    response = client.post(
        f"/dias/{dias[0]['id']}/gastos",
        json=_gasto_payload(client_id="gasto-60m-b", valor="60000000.00"),
    )

    assert response.status_code == 422
    assert response.json()["error"] == "total_da_viagem_acima_do_limite"

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 60000000.00
    dia = _dia_lido(corpo, dias[0]["id"])
    assert dia["saldo"] == 39999999.99
    assert [g["id"] for g in dia["gastos"]] == [primeiro["id"]]


def test_editar_gasto_para_valor_que_estoura_o_total_da_422(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-teto-editar")
    _gasto(client, dias[0]["id"], "gasto-60m", "60000000.00")
    gasto = _gasto(client, dias[1]["id"], "gasto-edita", "30.00")

    response = client.put(
        f"/gastos/{gasto['id']}",
        json=_gasto_payload(valor="50000000.00"),
    )

    assert response.status_code == 422
    assert response.json()["error"] == "total_da_viagem_acima_do_limite"

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 60000030.00
    assert _dia_lido(corpo, dias[0]["id"])["saldo"] == 39999999.99
    dia_edicao = _dia_lido(corpo, dias[1]["id"])
    assert dia_edicao["saldo"] == 99999969.99
    assert dia_edicao["gastos"][0]["id"] == gasto["id"]
    assert dia_edicao["gastos"][0]["valor"] == 30.00


def test_mover_e_subir_gasto_que_estoura_o_total_da_422(ambiente):
    """O PUT que muda de dia sobe o mesmo teto: mover dentro da viagem não
    escapa da conferência (o ciclo é sempre o mesmo)."""
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-teto-mover")
    _gasto(client, dias[0]["id"], "gasto-60m", "60000000.00")
    gasto = _gasto(client, dias[0]["id"], "gasto-move", "30.00")

    response = client.put(
        f"/gastos/{gasto['id']}",
        json=_gasto_payload(valor="50000000.00", dia_id=dias[1]["id"]),
    )

    assert response.status_code == 422
    assert response.json()["error"] == "total_da_viagem_acima_do_limite"

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 60000030.00
    assert _dia_lido(corpo, dias[1]["id"])["gastos"] == []


def test_gasto_que_leva_o_total_ao_teto_exato_passa(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-teto-exato")
    _gasto(client, dias[0]["id"], "gasto-60m", "60000000.00")

    response = client.post(
        f"/dias/{dias[1]['id']}/gastos",
        json=_gasto_payload(client_id="gasto-resto", valor="39999999.99"),
    )

    assert response.status_code == 200
    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 99999999.99


def test_reenvio_client_id_com_total_no_teto_devolve_200(ambiente):
    """A busca por `client_id` vem antes da conferência do teto: o reenvio do
    gasto já gravado não é um gasto novo e não pode esbarrar no limite."""
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-teto-reenvio")
    gasto = _gasto(client, dias[0]["id"], "gasto-teto", "99999999.99")

    response = client.post(
        f"/dias/{dias[0]['id']}/gastos",
        json=_gasto_payload(client_id="gasto-teto", valor="99999999.99"),
    )

    assert response.status_code == 200
    assert response.json()["id"] == gasto["id"]

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 99999999.99
    dia = _dia_lido(corpo, dias[0]["id"])
    assert [g["id"] for g in dia["gastos"]] == [gasto["id"]]


def test_remover_gasto_com_total_no_teto_nao_e_bloqueado(ambiente):
    """Diminuir o total sempre cabe na coluna: o DELETE passa mesmo com o
    `gasto_total` já no teto."""
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-teto-remover")
    gasto = _gasto(client, dias[0]["id"], "gasto-teto", "99999999.99")

    response = client.delete(f"/gastos/{gasto['id']}")

    assert response.status_code == 204
    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 0.00
