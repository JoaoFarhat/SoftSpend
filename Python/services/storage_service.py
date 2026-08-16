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
        config=Config(signature_version="s3v4"),
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


def salvar_comprovante(user_id: str, gasto_id: int, conteudo: bytes, content_type: str) -> str:
    if not _client:
        raise RuntimeError("Storage de comprovantes nao configurado")

    conteudo_jpeg, _ = _conteudo_para_jpeg(conteudo)
    key = _montar_key(user_id, gasto_id, "jpg")

    _client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=conteudo_jpeg,
        ContentType="image/jpeg",
    )

    return key


def remover_comprovante(key: str | None) -> None:
    """
    Apaga o objeto do bucket.

    Falhas sao apenas logadas: um objeto orfao no bucket e menos grave que
    impedir o usuario de deletar/atualizar o gasto dele.
    """
    if not key or not _client:
        return

    try:
        _client.delete_object(Bucket=S3_BUCKET, Key=key)
    except Exception as erro:
        logger.warning("Falha ao remover comprovante %s: %s", key, type(erro).__name__)


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
