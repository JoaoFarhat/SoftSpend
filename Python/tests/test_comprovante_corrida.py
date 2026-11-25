"""Dois pedidos mexendo na nota fiscal do mesmo gasto ao mesmo tempo.

`anexar_comprovante` lia a `comprovante_key` sem trava, subia a nota nova
(key única) e marcava a key lida para apagar: dois uploads ao mesmo tempo
liam a mesma key antiga, o último commit vencia e a nota do primeiro ficava
no bucket para sempre, sem nenhum gasto apontando para ela. Agora a key é
relida com `find_gasto_for_update` — só a linha do gasto, depois do upload —
e `remover_comprovante` faz o mesmo antes de escolher a key a apagar.

Mesmo molde de `test_remover_dia_corrida.py`: o outro pedido é simulado por
outra `Session(engine)` com commit, no meio do pedido testado. O storage é
falso (`monkeypatch`): um dicionário key → conteúdo, com a miniatura
derivada pela mesma convenção do `storage_service` (`<raiz>-thumb.jpg`).
"""

import uuid

from sqlalchemy.orm import Session

import models
from repositories import gasto_repository
from services import gasto_service, storage_service
from test_core_api import (
    USER_A,
    _criar_ciclo_dia_gasto,
    ambiente,  # fixture reutilizada de test_core_api
)

KEY_0 = "comprovantes/user-a/gasto-velha.jpg"
KEY_1 = "comprovantes/user-a/gasto-do-outro-pedido.jpg"


def _jpeg(tamanho: int = 1024) -> bytes:
    """JPEG pelos magic bytes: o `filetype` só olha os bytes iniciais."""
    return b"\xff\xd8\xff\xe0" + b"\x00" * (tamanho - 4)


def _thumb(key: str) -> str:
    return storage_service.thumb_key(key)


def _post_comprovante(client, gasto_id: int, conteudo: bytes):
    return client.post(
        f"/gastos/{gasto_id}/comprovante",
        files={"imagem": ("nota.jpg", conteudo, "image/jpeg")},
    )


def _storage_falso(monkeypatch) -> tuple[dict, list]:
    """Storage em memória: grava o original e a miniatura, como o S3 real.

    Devolve `(arquivos, subidas)`: `arquivos` é o bucket (key → bytes) e
    `subidas` guarda as keys devolvidas por `salvar_comprovante`, em ordem.
    """
    arquivos = {}
    subidas = []

    def _salvar(user_id, gasto_id, conteudo, content_type):
        key = f"comprovantes/{user_id}/{gasto_id}-{uuid.uuid4().hex[:12]}.jpg"
        arquivos[key] = conteudo
        arquivos[_thumb(key)] = b"miniatura"
        subidas.append(key)
        return key

    def _remover(keys):
        for key in keys:
            arquivos.pop(key, None)
            arquivos.pop(_thumb(key), None)

    monkeypatch.setattr(storage_service, "esta_configurado", lambda: True)
    monkeypatch.setattr(storage_service, "salvar_comprovante", _salvar)
    monkeypatch.setattr(storage_service, "remover_comprovantes", _remover)
    return arquivos, subidas


def _definir_comprovante(ambiente, gasto_id: int, key: str, arquivos: dict) -> None:
    """Estado de "nota já anexada": a key no banco e o arquivo no bucket."""
    ambiente.session.get(models.Gasto, gasto_id).comprovante_key = key
    ambiente.session.commit()
    arquivos[key] = b"nota"
    arquivos[_thumb(key)] = b"miniatura"


def _trocar_comprovante_em_outra_sessao(
    engine, gasto_id: int, key_nova: str, arquivos: dict, key_velha: str
) -> None:
    """O que o commit de outro pedido de anexar deixa para trás.

    A key nova gravada no gasto, a nota nova no bucket e a nota anterior
    removida — o `after_commit` dele já rodou.
    """
    with Session(engine) as outra:
        outra.query(models.Gasto).filter(models.Gasto.id == gasto_id).update(
            {models.Gasto.comprovante_key: key_nova}, synchronize_session=False
        )
        outra.commit()
    arquivos[key_nova] = b"nota-do-outro-pedido"
    arquivos[_thumb(key_nova)] = b"miniatura"
    arquivos.pop(key_velha, None)
    arquivos.pop(_thumb(key_velha), None)


def test_anexar_rele_o_gasto_com_trava_depois_do_upload(ambiente, monkeypatch):
    _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    eventos = []
    salvar = storage_service.salvar_comprovante
    travar = gasto_repository.find_gasto_for_update

    def espia_salvar(*args):
        eventos.append("upload")
        return salvar(*args)

    def espia_trava(db, gasto_id):
        eventos.append("trava")
        return travar(db, gasto_id)

    monkeypatch.setattr(storage_service, "salvar_comprovante", espia_salvar)
    monkeypatch.setattr(gasto_repository, "find_gasto_for_update", espia_trava)

    resposta = _post_comprovante(client, gasto["id"], _jpeg())

    assert resposta.status_code == 200
    # A linha não fica travada durante a rede: a trava vem depois do upload.
    assert eventos == ["upload", "trava"]


def test_remover_le_a_key_depois_da_trava(ambiente, monkeypatch):
    arquivos, _ = _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)
    _definir_comprovante(ambiente, gasto["id"], KEY_0, arquivos)

    eventos = []
    travar = gasto_repository.find_gasto_for_update
    marcar = gasto_service.marcar_comprovante_para_remover

    def espia_trava(db, gasto_id):
        eventos.append("trava")
        return travar(db, gasto_id)

    def espia_marcar(db, key):
        eventos.append(f"marcar:{key}")
        return marcar(db, key)

    monkeypatch.setattr(gasto_repository, "find_gasto_for_update", espia_trava)
    monkeypatch.setattr(
        gasto_service, "marcar_comprovante_para_remover", espia_marcar
    )

    resposta = client.delete(f"/gastos/{gasto['id']}/comprovante")

    assert resposta.status_code == 200
    # A key marcada para apagar vem da leitura com trava, não da conferência.
    assert eventos == ["trava", f"marcar:{KEY_0}"]


def test_segundo_upload_apaga_a_nota_que_o_primeiro_gravou(ambiente, monkeypatch):
    arquivos, subidas = _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)
    _definir_comprovante(ambiente, gasto["id"], KEY_0, arquivos)
    engine = ambiente.session.get_bind()

    travar = gasto_repository.find_gasto_for_update

    def com_corrida(db, gasto_id):
        # Entre o upload deste pedido e a releitura, outro pedido anexou
        # KEY_1 (gravando no gasto e no bucket) e apagou KEY_0.
        _trocar_comprovante_em_outra_sessao(
            engine, gasto_id, KEY_1, arquivos, KEY_0
        )
        return travar(db, gasto_id)

    monkeypatch.setattr(gasto_repository, "find_gasto_for_update", com_corrida)

    resposta = _post_comprovante(client, gasto["id"], _jpeg())

    assert resposta.status_code == 200
    # O `get_db` de verdade faz commit no fim do pedido; o do fixture não.
    ambiente.session.commit()

    key_nova = subidas[-1]
    gasto_db = ambiente.session.get(models.Gasto, gasto["id"])
    assert gasto_db.comprovante_key == key_nova
    # KEY_1 saiu do bucket com a nota velha: só a nota nova ficou.
    assert set(arquivos) == {key_nova, _thumb(key_nova)}


def test_gasto_apagado_durante_o_upload_descarta_a_nota_nova(
    ambiente, monkeypatch
):
    arquivos, _ = _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)
    engine = ambiente.session.get_bind()
    # Sem escrita pendente nesta sessão, a outra consegue gravar no SQLite.
    ambiente.session.commit()

    travar = gasto_repository.find_gasto_for_update

    def com_corrida(db, gasto_id):
        # Entre o upload e a releitura, outro pedido apagou o gasto.
        with Session(engine) as outra:
            outra.query(models.Gasto).filter(
                models.Gasto.id == gasto_id
            ).delete(synchronize_session=False)
            outra.commit()
        return travar(db, gasto_id)

    monkeypatch.setattr(gasto_repository, "find_gasto_for_update", com_corrida)

    resposta = _post_comprovante(client, gasto["id"], _jpeg())

    assert resposta.status_code == 404
    # O `get_db` de verdade faz rollback no erro; é o rollback que apaga a
    # nota subida pelo listener de comprovante_cleanup.
    ambiente.session.rollback()
    assert arquivos == {}


def test_remover_com_nota_trocada_por_outro_pedido_apaga_a_atual(
    ambiente, monkeypatch
):
    arquivos, _ = _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)
    _definir_comprovante(ambiente, gasto["id"], KEY_0, arquivos)
    engine = ambiente.session.get_bind()

    travar = gasto_repository.find_gasto_for_update

    def com_corrida(db, gasto_id):
        # Entre a conferência do dono e a trava, outro pedido trocou a nota:
        # a sessão deste pedido ficou com a foto de KEY_0.
        _trocar_comprovante_em_outra_sessao(
            engine, gasto_id, KEY_1, arquivos, KEY_0
        )
        return travar(db, gasto_id)

    monkeypatch.setattr(gasto_repository, "find_gasto_for_update", com_corrida)

    resposta = client.delete(f"/gastos/{gasto['id']}/comprovante")

    assert resposta.status_code == 200
    ambiente.session.commit()

    # Saiu a nota atual (KEY_1), não a foto velha (KEY_0): o bucket esvaziou.
    assert arquivos == {}
    gasto_db = ambiente.session.get(models.Gasto, gasto["id"])
    assert gasto_db.comprovante_key is None
