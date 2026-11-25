"""O 422 de validacao diz qual campo foi recusado.

Antes, todo `RequestValidationError` respondia so
`{"error": "Dados de entrada invalidos", "request_id"}` e o app gravava essa
frase no item, sem o usuario saber o que editar. Agora o corpo tambem traz
`campos`: o ultimo item de texto de cada `loc` (sem repeticao, na ordem dos
erros). O valor enviado (`input`) e o `ctx` nunca aparecem na resposta.
"""

from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    _ciclo_payload,
    _dia_payload,
    ambiente,
)


def test_ciclo_com_diaria_zero_lista_o_campo(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)

    resposta = client.post("/ciclos", json=_ciclo_payload(diaria="0"))

    assert resposta.status_code == 422
    corpo = resposta.json()
    assert corpo["campos"] == ["diaria"]
    assert corpo["error"] == "Dados de entrada invalidos"
    assert corpo["request_id"]


def test_dia_em_2062_no_lote_lista_o_campo_data(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = client.post("/ciclos", json=_ciclo_payload()).json()

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[_dia_payload("dia-2062", "2062-11-01T00:00:00Z")],
    )

    assert resposta.status_code == 422
    corpo = resposta.json()
    assert corpo["campos"] == ["data"]
    assert corpo["error"] == "Dados de entrada invalidos"
    assert corpo["request_id"]


def test_dois_campos_invalidos_lista_os_dois(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)

    resposta = client.post(
        "/ciclos", json=_ciclo_payload(titulo="", valor_total="0")
    )

    assert resposta.status_code == 422
    corpo = resposta.json()
    assert corpo["campos"] == ["valor_total", "titulo"]


def test_resposta_nao_vaza_o_valor_enviado(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    titulo_longo = "x" * 101

    resposta = client.post("/ciclos", json=_ciclo_payload(titulo=titulo_longo))

    assert resposta.status_code == 422
    assert resposta.json()["campos"] == ["titulo"]
    assert titulo_longo not in resposta.text
