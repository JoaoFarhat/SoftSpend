"""As rotas tiram a nota fiscal do bucket quando o gasto some.

`services/comprovante_cleanup.py` anota a `comprovante_key` no `after_delete`
do `Gasto` e apaga o arquivo no `after_commit` da sessão — é a promessa dos
Termos de que excluir a conta apaga os comprovantes. Cada teste aqui passa
pela rota: a requisição marca o delete e o `session.commit()` — que em
produção é feito pelo `get_db` — dispara a remoção.

O mock em `storage_service.remover_comprovantes` registra o que sairia para o
S3; cada caso confere a key removida exatamente uma vez.
"""

from unittest.mock import patch

import pytest
from sqlalchemy.exc import IntegrityError

import models
from test_core_api import (
    USER_A,
    _criar_ciclo,
    _criar_ciclo_dia_gasto,
    _dia_payload,
    _gasto_payload,
    ambiente,  # fixture reutilizada de test_core_api
)

REMOVER = "services.comprovante_cleanup.storage_service.remover_comprovantes"

KEY_1 = "comprovantes/user-a/gasto-1.jpg"
KEY_2 = "comprovantes/user-a/gasto-2.jpg"


def _definir_comprovante(session, gasto_id: int, key: str) -> None:
    """Grava a key direto no banco, como se o upload já tivesse acontecido."""
    session.get(models.Gasto, gasto_id).comprovante_key = key
    session.commit()


def _novo_dia(client, ciclo_id: int, client_id: str, data: str) -> dict:
    response = client.post(
        f"/ciclos/{ciclo_id}/dias", json=_dia_payload(client_id, data)
    )
    assert response.status_code == 200
    return response.json()


def _novo_gasto(client, dia_id: int, client_id: str) -> dict:
    response = client.post(
        f"/dias/{dia_id}/gastos", json=_gasto_payload(client_id=client_id)
    )
    assert response.status_code == 200
    return response.json()


def _keys_removidas(remover) -> set:
    return {
        key
        for chamada in remover.call_args_list
        for key in chamada.args[0]
    }


def test_delete_do_gasto_remove_o_comprovante_do_bucket(ambiente):
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)
    _definir_comprovante(ambiente.session, gasto["id"], KEY_1)

    with patch(REMOVER) as remover:
        assert client.delete(f"/gastos/{gasto['id']}").status_code == 204
        ambiente.session.commit()

    remover.assert_called_once_with({KEY_1})


def test_delete_do_dia_remove_os_comprovantes_dos_gastos(ambiente):
    client = ambiente.como(USER_A)
    _, dia, gasto = _criar_ciclo_dia_gasto(client)
    outro_gasto = _novo_gasto(client, dia["id"], "gasto-client-2")
    _definir_comprovante(ambiente.session, gasto["id"], KEY_1)
    _definir_comprovante(ambiente.session, outro_gasto["id"], KEY_2)

    with patch(REMOVER) as remover:
        assert client.delete(f"/dias/{dia['id']}").status_code == 204
        ambiente.session.commit()

    remover.assert_called_once()
    assert _keys_removidas(remover) == {KEY_1, KEY_2}


def test_delete_da_viagem_remove_os_comprovantes_em_cascata(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia_1 = _novo_dia(client, ciclo["id"], "dia-1", "2026-11-01T00:00:00Z")
    dia_2 = _novo_dia(client, ciclo["id"], "dia-2", "2026-11-02T00:00:00Z")
    gasto_1 = _novo_gasto(client, dia_1["id"], "gasto-client-1")
    gasto_2 = _novo_gasto(client, dia_2["id"], "gasto-client-2")
    _definir_comprovante(ambiente.session, gasto_1["id"], KEY_1)
    _definir_comprovante(ambiente.session, gasto_2["id"], KEY_2)

    with patch(REMOVER) as remover:
        assert client.delete(f"/ciclos/{ciclo['id']}").status_code == 204
        ambiente.session.commit()

    remover.assert_called_once()
    assert _keys_removidas(remover) == {KEY_1, KEY_2}


def test_delete_do_dia_nao_toca_no_comprovante_do_dia_que_fica(ambiente):
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia_1 = _novo_dia(client, ciclo["id"], "dia-1", "2026-11-01T00:00:00Z")
    dia_2 = _novo_dia(client, ciclo["id"], "dia-2", "2026-11-02T00:00:00Z")
    gasto_1 = _novo_gasto(client, dia_1["id"], "gasto-client-1")
    gasto_2 = _novo_gasto(client, dia_2["id"], "gasto-client-2")
    _definir_comprovante(ambiente.session, gasto_1["id"], KEY_1)
    _definir_comprovante(ambiente.session, gasto_2["id"], KEY_2)

    with patch(REMOVER) as remover:
        # A viagem encurta para um dia: o DELETE /dias/{id} apaga o dia_2.
        assert client.delete(f"/dias/{dia_2['id']}").status_code == 204
        ambiente.session.commit()

    remover.assert_called_once_with({KEY_2})


def test_delete_da_conta_remove_todos_os_comprovantes(ambiente):
    client = ambiente.como(USER_A)
    ciclo, dia_1, gasto_1 = _criar_ciclo_dia_gasto(client)
    dia_2 = _novo_dia(client, ciclo["id"], "dia-2", "2026-11-02T00:00:00Z")
    gasto_2 = _novo_gasto(client, dia_2["id"], "gasto-client-2")
    _definir_comprovante(ambiente.session, gasto_1["id"], KEY_1)
    _definir_comprovante(ambiente.session, gasto_2["id"], KEY_2)

    with patch(REMOVER) as remover:
        assert client.delete("/auth/conta").status_code == 204
        ambiente.session.commit()

    remover.assert_called_once()
    assert _keys_removidas(remover) == {KEY_1, KEY_2}
    assert ambiente.session.get(models.User, USER_A) is None


def test_comprovante_nao_sai_do_bucket_quando_o_commit_falha(ambiente):
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)
    _definir_comprovante(ambiente.session, gasto["id"], KEY_1)

    assert client.delete(f"/gastos/{gasto['id']}").status_code == 204

    # Falha real no commit (o insert abaixo esbarra na PK de users): a key
    # anotada não pode vazar para o storage, senão o comprovante de um gasto
    # que continuou vivo seria apagado do bucket.
    ambiente.session.add(
        models.User(
            id=USER_A,
            nome="Duplicado",
            username="duplicado",
            email="duplicado@example.com",
            senha_hash="hash",
        )
    )
    with patch(REMOVER) as remover, pytest.raises(IntegrityError):
        ambiente.session.commit()

    # O `except` do `get_db` chama rollback; sem ele a sessão não abre outra
    # transação para a releitura abaixo.
    ambiente.session.rollback()

    remover.assert_not_called()
    sobreviveu = ambiente.session.get(models.Gasto, gasto["id"])
    assert sobreviveu is not None
    assert sobreviveu.comprovante_key == KEY_1
