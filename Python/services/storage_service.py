import logging
import os
import uuid
from io import BytesIO

import boto3
from botocore.config import Config
from PIL import Image

logger = logging.getLogger(__name__)

S3_BUCKET = os.getenv("S3_BUCKET")
S3_REGION = os.getenv("S3_REGION", "auto")
URL_EXPIRACAO_SEGUNDOS = int(os.getenv("S3_URL_EXPIRACAO", str(3600)))

MAX_IMAGEM_LARGURA = int(os.getenv("S3_MAX_IMAGEM_LARGURA", "5000"))
MAX_IMAGEM_ALTURA = int(os.getenv("S3_MAX_IMAGEM_ALTURA", "5000"))

# Lado maior da miniatura usada no relatorio. Grande o suficiente para uma nota
# ficar legivel ampliada, pequeno o suficiente para o download em paralelo.
THUMB_LADO_MAIOR = int(os.getenv("S3_THUMB_LADO_MAIOR", "1400"))
THUMB_QUALIDADE = int(os.getenv("S3_THUMB_QUALIDADE", "75"))

# Escala de renderizacao do PDF. 2.0 ~ 144 DPI, suficiente para leitura.
PDF_ESCALA_RENDER = float(os.getenv("S3_PDF_ESCALA_RENDER", "2.0"))

SUFIXO_THUMB = "-thumb.jpg"

EXTENSOES_POR_CONTENT_TYPE = {
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/png": "png",
    "image/heic": "heic",
    "image/webp": "webp",
    "application/pdf": "pdf",
}

_client = (
    boto3.client(
        "s3",
        region_name=S3_REGION,
        aws_access_key_id=os.getenv("S3_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("S3_SECRET_ACCESS_KEY"),
        # O export baixa varias miniaturas em paralelo; com o default de 10 as
        # threads competiriam pelo pool e o paralelismo se perderia.
        config=Config(signature_version="s3v4", max_pool_connections=16),
    )
    if S3_BUCKET
    else None
)


def esta_configurado() -> bool:
    return _client is not None


def _formato_imagem_permitido(img: Image.Image) -> bool:
    return img.format in ("JPEG", "JPG", "PNG", "WEBP") and img.mode in ("RGB", "RGBA", "L")


def _conteudo_para_jpeg(conteudo: bytes) -> tuple[bytes, str]:
    """Valida que os bytes sao uma imagem permitida, limita dimensoes e converte para JPEG."""
    try:
        img = Image.open(BytesIO(conteudo))
    except Exception as e:
        raise ValueError(f"Arquivo nao e uma imagem valida: {e}")

    if not _formato_imagem_permitido(img):
        raise ValueError("Formato de imagem nao suportado. Use JPEG, PNG ou WEBP")

    if img.width > MAX_IMAGEM_LARGURA or img.height > MAX_IMAGEM_ALTURA:
        raise ValueError(f"Imagem excede as dimensoes maximas de {MAX_IMAGEM_LARGURA}x{MAX_IMAGEM_ALTURA}px")

    if img.mode != "RGB":
        img = img.convert("RGB")

    buffer = BytesIO()
    img.save(buffer, format="JPEG", quality=90)
    return buffer.getvalue(), "image/jpeg"


def _montar_key(user_id: str, gasto_id: int, extensao: str) -> str:
    return f"comprovantes/{user_id}/{gasto_id}-{uuid.uuid4().hex[:12]}.{extensao}"


def thumb_key(key: str) -> str:
    """Deriva a key da miniatura a partir da key do original.

    A convencao de nome evita coluna nova no banco: dado o comprovante_key,
    a miniatura e sempre `<raiz>-thumb.jpg`.
    """
    raiz, _, _ = key.rpartition(".")
    return f"{raiz or key}{SUFIXO_THUMB}"


def keys_do_comprovante(key: str) -> list[str]:
    """Todas as keys que compoem um comprovante (original + miniatura)."""
    return [key, thumb_key(key)]


def e_pdf(key: str | None) -> bool:
    return bool(key) and key.lower().endswith(".pdf")


def pdf_primeira_pagina_para_jpeg(conteudo: bytes) -> bytes:
    """Rasteriza a primeira pagina do PDF em JPEG.

    Usamos pypdfium2 porque distribui wheels self-contained (sem lib de
    sistema, diferente do poppler) e tem licenca permissiva, ao contrario do
    PyMuPDF (AGPL).
    """
    import pypdfium2 as pdfium

    try:
        documento = pdfium.PdfDocument(conteudo)
    except Exception as erro:
        raise ValueError(f"PDF invalido: {erro}")

    try:
        if len(documento) == 0:
            raise ValueError("PDF nao tem paginas")

        pagina = documento[0]
        imagem = pagina.render(scale=PDF_ESCALA_RENDER).to_pil()
    finally:
        documento.close()

    if imagem.mode != "RGB":
        imagem = imagem.convert("RGB")

    buffer = BytesIO()
    imagem.save(buffer, format="JPEG", quality=90)
    return buffer.getvalue()


def _gerar_thumb(conteudo_jpeg: bytes) -> bytes:
    """Reduz um JPEG para o tamanho da miniatura.

    `draft()` usa o escalonamento DCT do libjpeg para decodificar a imagem ja
    reduzida, em vez de decodificar em resolucao cheia e so depois redimensionar
    — bem mais rapido e com pico de memoria muito menor.
    """
    imagem = Image.open(BytesIO(conteudo_jpeg))
    imagem.draft("RGB", (THUMB_LADO_MAIOR, THUMB_LADO_MAIOR))
    imagem = imagem.convert("RGB")
    imagem.thumbnail((THUMB_LADO_MAIOR, THUMB_LADO_MAIOR), Image.LANCZOS)

    buffer = BytesIO()
    imagem.save(buffer, format="JPEG", quality=THUMB_QUALIDADE, optimize=True)
    return buffer.getvalue()


def salvar_comprovante(user_id: str, gasto_id: int, conteudo: bytes, content_type: str) -> str:
    """Grava o comprovante e sua miniatura, devolvendo a key do original.

    Sao sempre dois objetos: o original (`.pdf` ou `.jpg`) e a miniatura
    (`-thumb.jpg`) consumida pelo relatorio.
    """
    if not _client:
        raise RuntimeError("Storage de comprovantes nao configurado")

    if content_type == "application/pdf":
        # O original permanece PDF (o app abre o arquivo completo pelo link);
        # a miniatura sai da primeira pagina rasterizada.
        raster = pdf_primeira_pagina_para_jpeg(conteudo)
        key = _montar_key(user_id, gasto_id, "pdf")
        conteudo_original, tipo_original = conteudo, "application/pdf"
    else:
        raster, _ = _conteudo_para_jpeg(conteudo)
        key = _montar_key(user_id, gasto_id, "jpg")
        conteudo_original, tipo_original = raster, "image/jpeg"

    _client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=conteudo_original,
        ContentType=tipo_original,
    )

    # A miniatura e um cache: se falhar, o export ainda a gera sob demanda a
    # partir do original, entao nao vale derrubar o upload do usuario.
    try:
        _client.put_object(
            Bucket=S3_BUCKET,
            Key=thumb_key(key),
            Body=_gerar_thumb(raster),
            ContentType="image/jpeg",
        )
    except Exception as erro:
        logger.warning("Falha ao gravar miniatura de %s: %s", key, type(erro).__name__)

    return key


def remover_comprovante(key: str | None) -> None:
    """
    Apaga o original e a miniatura do bucket.

    Falhas sao apenas logadas: um objeto orfao no bucket e menos grave que
    impedir o usuario de deletar/atualizar o gasto dele.
    """
    if not key or not _client:
        return

    keys = keys_do_comprovante(key)

    try:
        _client.delete_objects(
            Bucket=S3_BUCKET,
            Delete={"Objects": [{"Key": k} for k in keys], "Quiet": True},
        )
    except Exception as erro:
        logger.warning("Falha ao remover comprovante %s: %s", key, type(erro).__name__)


def _baixar(key: str) -> bytes | None:
    try:
        resposta = _client.get_object(Bucket=S3_BUCKET, Key=key)
        return resposta["Body"].read()
    except Exception:
        return None


def carregar_thumb(key: str | None) -> bytes | None:
    """Devolve os bytes da miniatura para embutir no relatorio.

    Comprovantes gravados antes da miniatura existir caem no fallback: baixa o
    original, reduz em memoria e grava a miniatura para o proximo export nao
    pagar o mesmo custo (backfill preguicoso).
    """
    if not key or not _client:
        return None

    thumb = _baixar(thumb_key(key))
    if thumb is not None:
        return thumb

    original = _baixar(key)
    if original is None:
        logger.warning("Comprovante %s nao encontrado no bucket", key)
        return None

    try:
        if e_pdf(key):
            original = pdf_primeira_pagina_para_jpeg(original)
        thumb = _gerar_thumb(original)
    except Exception as erro:
        logger.warning("Falha ao gerar miniatura de %s: %s", key, type(erro).__name__)
        return None

    try:
        _client.put_object(
            Bucket=S3_BUCKET,
            Key=thumb_key(key),
            Body=thumb,
            ContentType="image/jpeg",
        )
    except Exception as erro:
        logger.warning("Falha no backfill da miniatura de %s: %s", key, type(erro).__name__)

    return thumb


def url_do_comprovante(key: str | None) -> str | None:
    if not key or not _client:
        return None

    try:
        return _client.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": key},
            ExpiresIn=URL_EXPIRACAO_SEGUNDOS,
        )
    except Exception as erro:
        logger.warning("Falha ao gerar URL do comprovante %s: %s", key, type(erro).__name__)
        return None
