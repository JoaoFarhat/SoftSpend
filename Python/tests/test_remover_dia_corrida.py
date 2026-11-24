"""Apagar um dia enquanto outro aparelho lança um gasto nele.

Antes, `remover_dia` lia o dia sem bloqueio e somava `dia.gastos` já
carregados na sessão: um gasto gravado por outro pedido entre a leitura e o
delete saía pelo cascade sem ser tirado do `ciclos.gasto_total`, e o total
da viagem ficava maior para sempre.

Aqui a corrida é simulada embrulhando o `find_dia` do repositório: ele lê o
dia, carrega a coleção `dia.gastos` e, logo depois, outra sessão grava um
gasto nesse dia (com o incremento do total, como faz o `criar_gasto`).
"""

from decimal import Decimal

from sqlalchemy.orm import Session

import models
from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    USER_B,
    _ciclo_payload,
    _dia_payload,
    _gasto_payload,
    ambiente,
)


def _cria_viagem(ambiente, com_gasto=True):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = client.post("/ciclos", json=_ciclo_payload()).json()
    dia = client.post(f"/ciclos/{ciclo['id']}/dias", json=_dia_payload()).json()
    if com_gasto:
        client.post(f"/dias/{dia['id']}/gastos", json=_gasto_payload(valor="30.00"))
    return client, ciclo, dia


def _espia_find_dia(monkeypatch, depois_de_ler=None):
    """Registra o `para_atualizar` de cada chamada e roda `depois_de_ler`."""
    from repositories import dia_repository

    original = dia_repository.find_dia
    chamadas = []

    def falso(*args, **kwargs):
        chamadas.append(kwargs.get("para_atualizar", False))
        dia = original(*args, **kwargs)
        if dia is not None and depois_de_ler is not None:
            depois_de_ler(dia)
        return dia

    monkeypatch.setattr(dia_repository, "find_dia", falso)
    return chamadas


def _gasto_total(ambiente, ciclo_id):  # noqa: F811
    with Session(ambiente.session.get_bind()) as leitura:
        return leitura.get(models.Ciclo, ciclo_id).gasto_total


def test_gasto_gravado_por_outra_sessao_e_descontado_ao_apagar_o_dia(
    ambiente, monkeypatch  # noqa: F811
):
    client, ciclo, dia = _cria_viagem(ambiente)
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("30.00")

    def outro_aparelho_lanca_gasto(dia_lido):
        # A coleção em memória fica só com o gasto antigo.
        assert len(dia_lido.gastos) == 1
        with Session(ambiente.session.get_bind()) as outra:
            outra.add(
                models.Gasto(
                    client_id="gasto-outro-aparelho",
                    dia_id=dia_lido.id,
                    titulo="Táxi",
                    valor=Decimal("40.00"),
                    categoria="TRANSPORTE",
                )
            )
            outra.get(models.Ciclo, dia_lido.ciclo_id).gasto_total += Decimal("40.00")
            outra.commit()

    _espia_find_dia(monkeypatch, outro_aparelho_lanca_gasto)

    resposta = client.delete(f"/dias/{dia['id']}")
    # O `get_db` do fixture não faz commit (o real faz no fim do pedido).
    ambiente.session.commit()

    assert resposta.status_code == 204
    # 30 + 40 entraram; os dois saíram junto com o dia.
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("0.00")
    assert client.get(f"/ciclos/{ciclo['id']}").json()["gasto_total"] == 0
    with Session(ambiente.session.get_bind()) as leitura:
        assert leitura.query(models.Dia).count() == 0
        assert leitura.query(models.Gasto).count() == 0


def test_apagar_dia_sem_gastos_nao_muda_o_total(ambiente):  # noqa: F811
    client, ciclo, dia = _cria_viagem(ambiente, com_gasto=False)
    outro = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload("dia-client-2", "2026-11-02T00:00:00Z"),
    ).json()
    client.post(f"/dias/{outro['id']}/gastos", json=_gasto_payload(valor="12.50"))

    resposta = client.delete(f"/dias/{dia['id']}")
    ambiente.session.commit()

    assert resposta.status_code == 204
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("12.50")


def test_remover_dia_le_o_dia_com_bloqueio(ambiente, monkeypatch):  # noqa: F811
    client, _, dia = _cria_viagem(ambiente)
    chamadas = _espia_find_dia(monkeypatch)

    resposta = client.delete(f"/dias/{dia['id']}")

    assert resposta.status_code == 204
    assert chamadas == [True]


def test_soma_do_dia_e_leitura_com_bloqueio_no_mysql(
    ambiente, monkeypatch  # noqa: F811
):
    """A soma também é leitura com bloqueio: no REPEATABLE READ do MySQL a
    leitura comum usaria a foto do começo da transação. O SQLite ignora o
    `FOR UPDATE`, então a consulta é compilada para o MySQL."""
    from sqlalchemy.dialects import mysql
    from sqlalchemy.orm import Query

    from repositories import gasto_repository

    consultas = []
    original = Query.scalar

    def espia(self):
        consultas.append(self)
        return original(self)

    monkeypatch.setattr(Query, "scalar", espia)

    gasto_repository.somar_valores_do_dia(ambiente.session, 1)

    assert len(consultas) == 1
    sql = str(consultas[0].statement.compile(dialect=mysql.dialect()))
    assert "sum(gastos_dia.valor)" in sql.lower()
    assert sql.rstrip().endswith("FOR UPDATE")


def test_soma_do_dia_le_o_banco(ambiente):  # noqa: F811
    from repositories import gasto_repository

    _, _, dia = _cria_viagem(ambiente)

    assert gasto_repository.somar_valores_do_dia(ambiente.session, dia["id"]) == Decimal(
        "30.00"
    )
    assert gasto_repository.somar_valores_do_dia(ambiente.session, 999_999) == 0


def test_apagar_dia_de_outro_usuario_continua_404(ambiente):  # noqa: F811
    _, ciclo, dia = _cria_viagem(ambiente)

    resposta = ambiente.como(USER_B).delete(f"/dias/{dia['id']}")

    assert resposta.status_code == 404
    assert _gasto_total(ambiente, ciclo["id"]) == Decimal("30.00")
    with Session(ambiente.session.get_bind()) as leitura:
        assert leitura.query(models.Dia).count() == 1
