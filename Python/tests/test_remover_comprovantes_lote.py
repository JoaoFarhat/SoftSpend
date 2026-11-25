"""As notas fiscais saem do bucket em lote, não uma por uma.

`storage_service.remover_comprovantes` junta original + miniatura de todas as
keys e apaga com `delete_objects` em partes de até 1000 objetos (teto da API
do S3). Antes cada nota era uma chamada, dentro do `db.commit()` do `get_db`,
e excluir a conta ou uma viagem com centenas de notas passava dos 8 s de
tempo limite do app.
"""

import models
from services import storage_service
from test_core_api import (
    USER_A,
    _criar_ciclo_dia_gasto,
    _gasto_payload,
    ambiente,  # fixture reutilizada de test_core_api
)


class _ClientFalso:
    """Grava o `Delete` de cada `delete_objects`; falha nas chamadas pedidas."""

    def __init__(self, falhar_na_chamada=()):
        self.deletes = []
        self._falhar = set(falhar_na_chamada)

    def delete_objects(self, Bucket, Delete):
        self.deletes.append(Delete)
        if len(self.deletes) in self._falhar:
            raise RuntimeError("S3 indisponível")
        return {}


def _novo_gasto(client, dia_id: int, client_id: str) -> dict:
    response = client.post(
        f"/dias/{dia_id}/gastos", json=_gasto_payload(client_id=client_id)
    )
    assert response.status_code == 200
    return response.json()


def _definir_comprovante(session, gasto_id: int, key: str) -> None:
    """Grava a key direto no banco, como se o upload já tivesse acontecido."""
    session.get(models.Gasto, gasto_id).comprovante_key = key
    session.commit()


def _objetos(falso) -> set:
    return {o["Key"] for delete in falso.deletes for o in delete["Objects"]}


def test_seiscentas_keys_saem_em_partes_de_ate_mil_objetos(monkeypatch):
    falso = _ClientFalso()
    monkeypatch.setattr(storage_service, "_client", falso)
    keys = [f"comprovantes/user-a/nota-{i}.jpg" for i in range(600)]

    storage_service.remover_comprovantes(keys)

    assert [len(d["Objects"]) for d in falso.deletes] == [1000, 200]
    assert all(d["Quiet"] for d in falso.deletes)
    assert _objetos(falso) == {
        objeto
        for key in keys
        for objeto in storage_service.keys_do_comprovante(key)
    }


def test_falha_numa_parte_nao_impede_a_seguinte(monkeypatch):
    falso = _ClientFalso(falhar_na_chamada={1})
    monkeypatch.setattr(storage_service, "_client", falso)
    keys = [f"comprovantes/user-a/nota-{i}.jpg" for i in range(600)]

    storage_service.remover_comprovantes(keys)

    # A segunda parte foi tentada mesmo com a primeira estourando.
    assert len(falso.deletes) == 2
    assert len(falso.deletes[1]["Objects"]) == 200


def test_delete_da_viagem_faz_uma_chamada_so_ao_bucket(ambiente, monkeypatch):
    client = ambiente.como(USER_A)
    ciclo, dia, gasto_1 = _criar_ciclo_dia_gasto(client)
    gasto_2 = _novo_gasto(client, dia["id"], "gasto-client-2")
    gasto_3 = _novo_gasto(client, dia["id"], "gasto-client-3")
    keys = []
    for i, gasto in enumerate((gasto_1, gasto_2, gasto_3), start=1):
        key = f"comprovantes/user-a/nota-{i}.jpg"
        _definir_comprovante(ambiente.session, gasto["id"], key)
        keys.append(key)

    falso = _ClientFalso()
    monkeypatch.setattr(storage_service, "_client", falso)

    assert client.delete(f"/ciclos/{ciclo['id']}").status_code == 204
    ambiente.session.commit()

    assert len(falso.deletes) == 1
    assert _objetos(falso) == {
        objeto
        for key in keys
        for objeto in storage_service.keys_do_comprovante(key)
    }
    assert len(_objetos(falso)) == 6
