"""Comprovante com bytes cortados no `POST /gastos/{id}/comprovante`.

O `Image.open` (e o `PdfDocument`) so valida o cabecalho: um JPEG gerado pelo
Pillow e truncado na metade abre, mas falha ao decodificar os pixels em
`exif_transpose`/`thumbnail`/`convert`/`save` — e um PDF que abre pode falhar
no `render`. Antes esses erros vazavam e a rota respondia 500, com o app
repetindo o upload em backoff sem o usuario saber o que fazer. Agora caem no
mesmo `ValueError` do arquivo ilegivel, que vira 422.
"""

from io import BytesIO

import pytest
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


def _jpeg(largura: int, altura: int) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (largura, altura), (180, 90, 40)).save(buffer, format="JPEG")
    return buffer.getvalue()


def _pdf_uma_pagina() -> bytes:
    """PDF de verdade, gerado pelo proprio pypdfium2."""
    import pypdfium2 as pdfium

    documento = pdfium.PdfDocument.new()
    documento.new_page(612, 792)
    buffer = BytesIO()
    documento.save(buffer)
    documento.close()
    return buffer.getvalue()


def test_jpeg_cortado_no_meio_vira_value_error():
    """3000x2000 cortado na metade dos bytes: abre, mas falha ao decodificar."""
    metade = _jpeg(3000, 2000)
    cortado = metade[: len(metade) // 2]

    with pytest.raises(ValueError, match="Não foi possível abrir esta imagem"):
        storage_service._conteudo_para_jpeg(cortado)


def test_jpeg_cortado_na_rota_da_422_e_nada_sobe(ambiente, monkeypatch):
    """Pela rota: 422 com a frase do arquivo ilegivel e nada gravado no S3."""
    falso = _S3Falso()
    monkeypatch.setattr(storage_service, "_client", falso)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    metade = _jpeg(3000, 2000)
    resposta = client.post(
        f"/gastos/{gasto['id']}/comprovante",
        files={
            "imagem": ("nota.jpg", metade[: len(metade) // 2], "image/jpeg")
        },
    )

    assert resposta.status_code == 422
    assert resposta.json()["error"] == (
        "Não foi possível abrir esta imagem; anexe outra foto"
    )
    assert falso.objetos == {}
    assert ambiente.session.get(models.Gasto, gasto["id"]).comprovante_key is None


def test_pdf_com_render_quebrado_vira_value_error(monkeypatch):
    """PDF que abre mas cujo `render` falha: ValueError com a frase do PDF."""
    import pypdfium2 as pdfium

    def _render_quebrado(self, *args, **kwargs):
        raise RuntimeError("rasterizacao falhou")

    monkeypatch.setattr(pdfium.PdfPage, "render", _render_quebrado)

    with pytest.raises(ValueError, match="Não foi possível abrir este PDF"):
        storage_service.pdf_primeira_pagina_para_jpeg(_pdf_uma_pagina())


def test_imagem_boa_segue_convertendo_para_jpeg():
    jpeg, content_type = storage_service._conteudo_para_jpeg(_jpeg(3000, 2000))

    assert content_type == "image/jpeg"
    assert Image.open(BytesIO(jpeg)).size == (3000, 2000)


def test_pdf_bom_segue_rasterizando_para_jpeg():
    jpeg = storage_service.pdf_primeira_pagina_para_jpeg(_pdf_uma_pagina())

    assert jpeg[:2] == b"\xff\xd8"  # JPEG
