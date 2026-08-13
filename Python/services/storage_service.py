import logging
import os
import uuid

import boto3
from botocore.config import Config

logger = logging.getLogger(__name__)

S3_BUCKET = os.getenv("S3_BUCKET")
S3_REGION = os.getenv("S3_REGION", "auto")
URL_EXPIRACAO_SEGUNDOS = int(os.getenv("S3_URL_EXPIRACAO", str(7 * 24 * 3600)))

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


def _montar_key(user_id: int, gasto_id: int, content_type: str) -> str:
    extensao = EXTENSOES_POR_CONTENT_TYPE.get(content_type, "jpg")
    return f"comprovantes/{user_id}/{gasto_id}-{uuid.uuid4().hex[:12]}.{extensao}"


def salvar_comprovante(user_id: int, gasto_id: int, conteudo: bytes, content_type: str) -> str:

    if not _client:
        raise RuntimeError("Storage de comprovantes nao configurado")

    if content_type not in EXTENSOES_POR_CONTENT_TYPE:
        raise ValueError(f"Tipo de arquivo nao suportado: {content_type}")

    key = _montar_key(user_id, gasto_id, content_type)

    _client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=conteudo,
        ContentType=content_type,
    )

    return key

def salvar_comprovante_fileobj(user_id: int, gasto_id: int, file_obj, content_type: str) -> str:
    if not _client:
        raise RuntimeError("Storage de comprovantes nao configurado")

    if content_type not in EXTENSOES_POR_CONTENT_TYPE:
        raise ValueError(f"Tipo de arquivo nao suportado: {content_type}")

    key = _montar_key(user_id, gasto_id, content_type)

    _client.upload_fileobj(
        Fileobj=file_obj,
        Bucket=S3_BUCKET,
        Key=key,
        ExtraArgs={"ContentType": content_type},
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
        logger.warning("Falha ao remover comprovante %s: %s", key, erro)


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
        logger.warning("Falha ao gerar URL do comprovante %s: %s", key, erro)
        return None
