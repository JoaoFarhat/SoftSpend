"""Foto da nota gravada na orientacao certa e com teto de pixels.

O app manda a foto da camera com a marca de orientacao (EXIF) e o
`_conteudo_para_jpeg` regravava o JPEG sem aplica-la — a nota aparecia
deitada no PDF do relatorio e no link. Agora `ImageOps.exif_transpose` gira
os pixels antes de medir/reduzir (o `ocr_service` ja fazia isso).

O teto `MAX_IMAGEM_PIXELS` (`S3_MAX_IMAGEM_PIXELS`, padrao 70 Mpx — acima do
panorama do iPhone) e conferido logo apos o `Image.open`, que so le o
cabecalho: um PNG de 10 MB pode ter ~170 milhoes de pixels e ocupar ~700 MB
ao decodificar. Acima dele o upload responde 422 e o OCR levanta
`SemRespostaGemini` (a cota do dia volta).

O `storage_service._client` e trocado por um falso que guarda os `put_object`,
para o `salvar_comprovante` real rodar de ponta a ponta sem S3.
"""

from io import BytesIO

import pytest
from PIL import Image

import models
from services import ocr_service, storage_service

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


def _jpeg(largura: int, altura: int, orientacao: int | None = None) -> bytes:
    imagem = Image.new("RGB", (largura, altura), (180, 90, 40))
    buffer = BytesIO()
    if orientacao is None:
        imagem.save(buffer, format="JPEG")
    else:
        exif = Image.Exif()
        exif[0x0112] = orientacao
        imagem.save(buffer, format="JPEG", exif=exif)
    return buffer.getvalue()


def _png(largura: int, altura: int) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (largura, altura), (40, 90, 180)).save(buffer, format="PNG")
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


def test_foto_com_exif_sobe_na_orientacao_certa(ambiente, monkeypatch):
    """JPEG 400x200 com EXIF orientation 6: o original gravado fica 200x400."""
    falso = _s3_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(
        client, gasto["id"], _jpeg(400, 200, orientacao=6), "image/jpeg"
    )

    assert resposta.status_code == 200
    assert _dimensoes(_original(falso)) == (200, 400)


def test_foto_sem_exif_mantem_dimensoes(ambiente, monkeypatch):
    falso = _s3_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(client, gasto["id"], _jpeg(400, 200), "image/jpeg")

    assert resposta.status_code == 200
    assert _dimensoes(_original(falso)) == (400, 200)


def test_imagem_acima_do_teto_de_pixels_da_422(ambiente, monkeypatch):
    """PNG 200x200 com o teto derrubado para 10.000 px: 422 e nada gravado."""
    falso = _s3_falso(monkeypatch)
    monkeypatch.setattr(storage_service, "MAX_IMAGEM_PIXELS", 10_000)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(
        client, gasto["id"], _png(200, 200), "image/png"
    )

    assert resposta.status_code == 422
    assert resposta.json()["error"] == (
        "Imagem grande demais; tire outra foto ou anexe um PDF"
    )
    assert falso.objetos == {}
    assert ambiente.session.get(models.Gasto, gasto["id"]).comprovante_key is None


def test_ocr_recusa_imagem_acima_do_teto_de_pixels(monkeypatch):
    monkeypatch.setattr(storage_service, "MAX_IMAGEM_PIXELS", 10_000)

    with pytest.raises(ocr_service.SemRespostaGemini) as erro:
        ocr_service._preprocessar_imagem(_png(200, 200))

    assert erro.value.status_code == 422
    assert erro.value.detail == (
        "Imagem grande demais; tire outra foto ou anexe um PDF"
    )


def test_ocr_devolve_imagem_em_pe():
    """EXIF 6 no preprocessamento do OCR: os pixels saem girados (200x400)."""
    resultado = ocr_service._preprocessar_imagem(_jpeg(400, 200, orientacao=6))

    assert _dimensoes(resultado) == (200, 400)
