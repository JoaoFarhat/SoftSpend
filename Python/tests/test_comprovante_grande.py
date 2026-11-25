"""Foto grande ou estragada de nota fiscal no `POST /gastos/{id}/comprovante`.

A camera dos iPhone 15/16 tira 5712x4284, acima do teto de 5000 px que o
`_conteudo_para_jpeg` exigia — a foto era recusada e a rota caia em 500, com
o app repetindo o upload para sempre. Agora a imagem e reduzida mantendo a
proporcao, e os arquivos ilegiveis viram 422 com mensagem para o usuario.

O `storage_service._client` e trocado por um falso que guarda os `put_object`,
para o `salvar_comprovante` real rodar de ponta a ponta sem S3.
"""

from io import BytesIO

from PIL import Image

import models
from services import storage_service

from test_core_api import (
    USER_A,
    _criar_ciclo_dia_gasto,
    ambiente,  # fixture reutilizada de test_core_api
)


class _S3Falso:
    """S3 em memoria: guarda o que `put_object` gravaria."""

    def __init__(self):
        self.objetos = {}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.objetos[Key] = Body


def _s3_falso(monkeypatch) -> _S3Falso:
    falso = _S3Falso()
    monkeypatch.setattr(storage_service, "_client", falso)
    return falso


def _jpeg(largura: int, altura: int) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (largura, altura), (180, 90, 40)).save(buffer, format="JPEG")
    return buffer.getvalue()


def _post_comprovante(client, gasto_id: int, conteudo: bytes, content_type: str):
    nome = "nota.pdf" if content_type == "application/pdf" else "nota.jpg"
    return client.post(
        f"/gastos/{gasto_id}/comprovante",
        files={"imagem": (nome, conteudo, content_type)},
    )


def _dimensoes(jpeg: bytes) -> tuple[int, int]:
    return Image.open(BytesIO(jpeg)).size


def _original(falso: _S3Falso) -> bytes:
    """O objeto gravado que nao e a miniatura."""
    key = next(
        k for k in falso.objetos if not k.endswith(storage_service.SUFIXO_THUMB)
    )
    return falso.objetos[key]


def test_foto_maior_que_o_teto_sobe_reduzida(ambiente, monkeypatch):
    """6000x4000 (foto do iPhone 15/16) sobe: lado maior vira 5000, 3:2 mantido."""
    falso = _s3_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(client, gasto["id"], _jpeg(6000, 4000), "image/jpeg")

    assert resposta.status_code == 200
    largura, altura = _dimensoes(_original(falso))
    assert max(largura, altura) == 5000
    assert abs(largura / altura - 3 / 2) < 0.01


def test_foto_dentro_do_teto_sobe_sem_reducao(ambiente, monkeypatch):
    falso = _s3_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(client, gasto["id"], _jpeg(4000, 3000), "image/jpeg")

    assert resposta.status_code == 200
    assert _dimensoes(_original(falso)) == (4000, 3000)


def test_imagem_estragada_da_422_sem_texto_tecnico(ambiente, monkeypatch):
    """Cabecalho JPEG seguido de lixo: 422 com mensagem limpa e nada gravado."""
    falso = _s3_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(
        client, gasto["id"], b"\xff\xd8\xff\xe0" + b"\x00" * 1024, "image/jpeg"
    )

    assert resposta.status_code == 422
    assert resposta.json()["error"] == (
        "Não foi possível abrir esta imagem; anexe outra foto"
    )
    assert "cannot identify" not in resposta.text
    assert falso.objetos == {}
    assert ambiente.session.get(models.Gasto, gasto["id"]).comprovante_key is None


def test_pdf_estragado_da_422_sem_texto_tecnico(ambiente, monkeypatch):
    """Cabecalho %PDF- seguido de lixo: 422, sem o erro interno do pdfium."""
    falso = _s3_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(
        client, gasto["id"], b"%PDF-" + b"\x00" * 1024, "application/pdf"
    )

    assert resposta.status_code == 422
    assert resposta.json()["error"] == (
        "Não foi possível abrir este PDF; anexe outro arquivo"
    )
    assert falso.objetos == {}
    assert ambiente.session.get(models.Gasto, gasto["id"]).comprovante_key is None
