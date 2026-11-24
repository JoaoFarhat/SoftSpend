"""Contas de dinheiro por incremento: `saldo` do dia e `gasto_total` da viagem.

A criacao ja e coberta em `test_core_api.py`; aqui entram as operacoes que
mexem nos incrementos depois: editar o valor de um gasto, mover um gasto
para outro dia (da mesma viagem ou de outra), apagar gasto, apagar dia com
gastos e encurtar a viagem pelo `DELETE /dias/{id}` (o caminho que o app usa:
o `PUT /ciclos/{id}/dias/lote`, que apagava os dias fora da lista, saiu do ar).

O ultimo teste cobre o desempate da paginacao de `GET /ciclos/{id}/dias`: o
POST de dia aceita duas datas iguais e, sem `id` no `ORDER BY`, `skip`/`limit`
podem repetir um dia e pular outro — e o app apaga localmente o dia que
"sumiu" da lista completa.
"""

from sqlalchemy import event

from test_core_api import (  # noqa: F401  (`ambiente` e o fixture do core)
    USER_A,
    USER_B,
    _ciclo_payload,
    _dia_payload,
    _gasto_payload,
    ambiente,
)

DATAS = [
    "2026-11-01T00:00:00Z",
    "2026-11-02T00:00:00Z",
    "2026-11-03T00:00:00Z",
]


def _viagem(client, client_id, valor_total="300.00", diaria="100.00", datas=DATAS):
    """Viagem pela rota: POST /ciclos + POST /ciclos/{id}/dias/lote."""
    response = client.post(
        "/ciclos",
        json=_ciclo_payload(
            client_id=client_id, valor_total=valor_total, diaria=diaria
        ),
    )
    assert response.status_code == 200
    ciclo = response.json()

    if not datas:
        return ciclo, []

    response = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload(f"{client_id}-dia-{i + 1}", data)
            for i, data in enumerate(datas)
        ],
    )
    assert response.status_code == 200
    return ciclo, response.json()


def _gasto(client, dia_id, client_id, valor="30.00"):
    response = client.post(
        f"/dias/{dia_id}/gastos",
        json=_gasto_payload(client_id=client_id, valor=valor),
    )
    assert response.status_code == 200
    return response.json()


def _estado(client, ciclo_id):
    """Leitura pela rota: `gasto_total` da viagem e `saldo` por id de dia."""
    response = client.get(f"/ciclos/{ciclo_id}")
    assert response.status_code == 200
    corpo = response.json()
    return corpo["gasto_total"], {
        dia["id"]: dia["saldo"] for dia in corpo["dias"]
    }


def test_editar_valor_do_gasto_atualiza_saldo_e_total(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-editar")
    gasto = _gasto(client, dias[0]["id"], "gasto-editar")

    response = client.put(
        f"/gastos/{gasto['id']}", json=_gasto_payload(valor="45.00")
    )
    assert response.status_code == 200

    total, saldos = _estado(client, ciclo["id"])
    assert total == 45.00
    assert saldos[dias[0]["id"]] == 55.00
    assert saldos[dias[1]["id"]] == 100.00
    assert saldos[dias[2]["id"]] == 100.00


def test_mover_gasto_para_outro_dia_mudando_valor(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-mover")
    gasto = _gasto(client, dias[0]["id"], "gasto-mover")

    response = client.put(
        f"/gastos/{gasto['id']}",
        json=_gasto_payload(valor="45.00", dia_id=dias[1]["id"]),
    )
    assert response.status_code == 200
    assert response.json()["valor"] == 45.00

    total, saldos = _estado(client, ciclo["id"])
    assert total == 45.00
    assert saldos[dias[0]["id"]] == 100.00
    assert saldos[dias[1]["id"]] == 55.00
    assert saldos[dias[2]["id"]] == 100.00

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    gastos_por_dia = {d["id"]: d["gastos"] for d in corpo["dias"]}
    assert [g["id"] for g in gastos_por_dia[dias[1]["id"]]] == [gasto["id"]]
    assert gastos_por_dia[dias[0]["id"]] == []


def test_mover_gasto_para_dia_de_outra_viagem_da_400_e_nada_muda(ambiente):
    client = ambiente.como(USER_A)
    ciclo_a, dias_a = _viagem(client, "ciclo-origem")
    ciclo_b, dias_b = _viagem(
        client, "ciclo-destino", valor_total="1200.00", diaria="400.00"
    )
    gasto = _gasto(client, dias_a[0]["id"], "gasto-entre-viagens")

    response = client.put(
        f"/gastos/{gasto['id']}",
        json=_gasto_payload(valor="45.00", dia_id=dias_b[0]["id"]),
    )
    assert response.status_code == 400

    total_a, saldos_a = _estado(client, ciclo_a["id"])
    assert total_a == 30.00
    assert saldos_a[dias_a[0]["id"]] == 70.00
    assert saldos_a[dias_a[1]["id"]] == 100.00
    assert saldos_a[dias_a[2]["id"]] == 100.00

    total_b, saldos_b = _estado(client, ciclo_b["id"])
    assert total_b == 0.00
    assert all(saldo == 400.00 for saldo in saldos_b.values())


def test_mover_gasto_para_dia_de_outro_usuario_da_404_e_nada_muda(ambiente):
    client = ambiente.como(USER_A)
    ciclo_a, dias_a = _viagem(client, "ciclo-do-a")
    gasto = _gasto(client, dias_a[0]["id"], "gasto-do-a")

    client_b = ambiente.como(USER_B)
    ciclo_b, dias_b = _viagem(
        client_b, "ciclo-do-b", valor_total="1200.00", diaria="400.00"
    )

    client = ambiente.como(USER_A)
    response = client.put(
        f"/gastos/{gasto['id']}",
        json=_gasto_payload(valor="45.00", dia_id=dias_b[0]["id"]),
    )
    assert response.status_code == 404

    total_a, saldos_a = _estado(client, ciclo_a["id"])
    assert total_a == 30.00
    assert saldos_a[dias_a[0]["id"]] == 70.00
    assert saldos_a[dias_a[1]["id"]] == 100.00
    assert saldos_a[dias_a[2]["id"]] == 100.00

    client_b = ambiente.como(USER_B)
    total_b, saldos_b = _estado(client_b, ciclo_b["id"])
    assert total_b == 0.00
    assert all(saldo == 400.00 for saldo in saldos_b.values())

    corpo_b = client_b.get(f"/ciclos/{ciclo_b['id']}").json()
    assert all(dia["gastos"] == [] for dia in corpo_b["dias"])


def test_mover_gasto_para_dia_inexistente_da_404_e_nada_muda(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-dia-inexistente")
    gasto = _gasto(client, dias[0]["id"], "gasto-dia-inexistente")

    response = client.put(
        f"/gastos/{gasto['id']}",
        json=_gasto_payload(valor="45.00", dia_id=999999),
    )
    assert response.status_code == 404

    total, saldos = _estado(client, ciclo["id"])
    assert total == 30.00
    assert saldos[dias[0]["id"]] == 70.00
    assert saldos[dias[1]["id"]] == 100.00
    assert saldos[dias[2]["id"]] == 100.00

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    gastos_dia = next(d["gastos"] for d in corpo["dias"] if d["id"] == dias[0]["id"])
    assert [g["id"] for g in gastos_dia] == [gasto["id"]]
    assert gastos_dia[0]["valor"] == 30.00


def test_apagar_gasto_devolve_saldo_e_total(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-apagar-gasto")
    gasto = _gasto(client, dias[0]["id"], "gasto-apagar")

    response = client.delete(f"/gastos/{gasto['id']}")
    assert response.status_code == 204

    total, saldos = _estado(client, ciclo["id"])
    assert total == 0.00
    assert all(saldo == 100.00 for saldo in saldos.values())


def test_apagar_dia_com_gastos_tira_so_dele_do_total(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-apagar-dia")
    _gasto(client, dias[0]["id"], "gasto-dia-1a", valor="30.00")
    _gasto(client, dias[0]["id"], "gasto-dia-1b", valor="20.00")
    _gasto(client, dias[1]["id"], "gasto-dia-2", valor="10.00")

    response = client.delete(f"/dias/{dias[0]['id']}")
    assert response.status_code == 204

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 10.00
    assert {d["id"] for d in corpo["dias"]} == {dias[1]["id"], dias[2]["id"]}
    assert all(d["saldo"] == 100.00 for d in corpo["dias"] if d["id"] == dias[2]["id"])
    assert next(
        d for d in corpo["dias"] if d["id"] == dias[1]["id"]
    )["saldo"] == 90.00


def test_encurtar_viagem_remove_do_total_gasto_do_dia_cortado(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dias = _viagem(client, "ciclo-encurtar")
    _gasto(client, dias[0]["id"], "gasto-fica", valor="10.00")
    _gasto(client, dias[2]["id"], "gasto-sai", valor="30.00")

    response = client.delete(f"/dias/{dias[2]['id']}")
    assert response.status_code == 204

    corpo = client.get(f"/ciclos/{ciclo['id']}").json()
    assert corpo["gasto_total"] == 10.00
    assert {d["id"] for d in corpo["dias"]} == {dias[0]["id"], dias[1]["id"]}
    assert next(
        d for d in corpo["dias"] if d["id"] == dias[0]["id"]
    )["saldo"] == 90.00


def test_dias_com_mesma_data_paginam_sem_repetir_nem_pular(ambiente):
    client = ambiente.como(USER_A)
    ciclo, _ = _viagem(client, "ciclo-pagina", datas=[])

    ids = []
    for i in range(3):
        response = client.post(
            f"/ciclos/{ciclo['id']}/dias",
            json=_dia_payload(f"mesma-data-{i + 1}", DATAS[0]),
        )
        assert response.status_code == 200
        ids.append(response.json()["id"])

    statements = []

    def _capturar(orm_execute_state):
        statements.append(str(orm_execute_state.statement))

    event.listen(ambiente.session, "do_orm_execute", _capturar)
    try:
        paginas = [
            client.get(
                f"/ciclos/{ciclo['id']}/dias", params={"skip": i, "limit": 1}
            ).json()
            for i in range(4)
        ]
    finally:
        event.remove(ambiente.session, "do_orm_execute", _capturar)

    assert paginas[3] == []
    assert [pagina[0]["id"] for pagina in paginas[:3]] == ids

    # Sem `id` no ORDER BY o SQLite devolve os dias em ordem de rowid e as
    # paginas acima sairiam iguais: a assercao do SQL emitido e o que faz o
    # teste falhar de verdade sem o desempate.
    listagens = [
        s for s in statements if "FROM dias" in s and "ORDER BY" in s
    ]
    assert listagens
    for listagem in listagens:
        assert "ORDER BY dias.data, dias.id" in listagem
