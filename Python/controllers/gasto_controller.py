from fastapi import APIRouter, Depends, UploadFile, File, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from sqlalchemy.orm import Session
import filetype
from database import get_db
from dependencies import get_current_user_id
from dtos.gasto import GastoResponse, GastoRequest, GastoExtraidoResponse
from services import gasto_service, ocr_service, storage_service
from limiter import limiter

router = APIRouter()

TAMANHO_MAXIMO_IMAGEM = 5 * 1024 * 1024
# Recibo em PDF (ex: Uber) costuma ser maior que uma foto de cupom.
TAMANHO_MAXIMO_PDF = 10 * 1024 * 1024


@router.post("/dias/{dia_id}/gastos", response_model=GastoResponse)
@limiter.limit("60/minute")
def criar_gasto(request: Request, dia_id: int, gasto: GastoRequest, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return gasto_service.criar_gasto(db, dia_id, gasto, user_id)


@router.put("/gastos/{gasto_id}", response_model=GastoResponse)
@limiter.limit("60/minute")
def atualizar_gasto(request: Request, gasto_id: int, gasto: GastoRequest, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return gasto_service.atualizar_gasto(db, gasto_id, gasto, user_id)


@router.delete("/gastos/{gasto_id}", status_code=204)
@limiter.limit("20/minute")
def deletar_gasto(request: Request, gasto_id: int, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return gasto_service.remover_gasto(db, gasto_id, user_id)


MIME_TYPES_PERMITIDOS = {"image/jpeg", "image/jpg", "image/png", "image/webp"}
MIME_TYPE_PDF = "application/pdf"


def _limite_para(content_type: str) -> tuple[int, str]:
    if content_type == MIME_TYPE_PDF:
        return TAMANHO_MAXIMO_PDF, "PDF muito grande (max 10MB)"
    return TAMANHO_MAXIMO_IMAGEM, "Imagem muito grande (max 5MB)"


async def _ler_arquivo(arquivo: UploadFile, permitir_pdf: bool = False) -> tuple[bytes, str]:
    """Le e valida o upload, devolvendo o conteudo e o MIME real (magic bytes).

    O MIME declarado pelo client serve so para a rejeicao antecipada; o tipo
    que vale e o detectado pelos magic bytes.
    """
    tipos_aceitos = set(MIME_TYPES_PERMITIDOS)
    if permitir_pdf:
        tipos_aceitos.add(MIME_TYPE_PDF)

    if permitir_pdf:
        erro_tipo = "Arquivo deve ser uma imagem (JPEG, PNG ou WEBP) ou um PDF"
    else:
        erro_tipo = "Arquivo deve ser uma imagem (JPEG, PNG ou WEBP)"

    if not arquivo.content_type or arquivo.content_type not in tipos_aceitos:
        raise HTTPException(status_code=400, detail=erro_tipo)

    tamanho_maximo, erro_tamanho = _limite_para(arquivo.content_type)

    # Aborta o mais cedo possível se o client declarar Content-Length
    if arquivo.size is not None and arquivo.size > tamanho_maximo:
        raise HTTPException(status_code=413, detail=erro_tamanho)

    # Lê em chunks para não carregar arquivos gigantes inteiros em memória/disco
    # caso o Content-Length esteja ausente ou seja mentiroso.
    conteudo = b""
    chunk_size = 64 * 1024
    while True:
        chunk = await arquivo.read(chunk_size)
        if not chunk:
            break
        conteudo += chunk
        if len(conteudo) > tamanho_maximo:
            raise HTTPException(status_code=413, detail=erro_tamanho)

    kind = filetype.guess(conteudo)
    if kind is None or kind.mime not in tipos_aceitos:
        raise HTTPException(status_code=400, detail="Conteúdo do arquivo não corresponde ao tipo declarado")

    # O limite depende do tipo real, nao do declarado, senao um PDF renomeado
    # como imagem escaparia do limite menor.
    tamanho_maximo_real, erro_tamanho_real = _limite_para(kind.mime)
    if len(conteudo) > tamanho_maximo_real:
        raise HTTPException(status_code=413, detail=erro_tamanho_real)

    return conteudo, kind.mime


@router.post("/gastos/extrair", response_model=GastoExtraidoResponse)
@limiter.limit("20/minute")
async def extrair_gasto_de_imagem(request: Request, imagem: UploadFile = File(...), user_id: str = Depends(get_current_user_id)):
    conteudo, mime = await _ler_arquivo(imagem, permitir_pdf=True)

    try:
        # O OCR so aceita imagem, entao um recibo em PDF entra pela primeira
        # pagina rasterizada.
        if mime == MIME_TYPE_PDF:
            conteudo = await run_in_threadpool(
                storage_service.pdf_primeira_pagina_para_jpeg, conteudo
            )

        dados = await run_in_threadpool(ocr_service.extrair_gasto_da_imagem, conteudo)
        return dados
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except Exception:
        raise HTTPException(status_code=500, detail="Erro ao processar imagem")


@router.post("/gastos/{gasto_id}/comprovante", response_model=GastoResponse)
@limiter.limit("30/minute")
async def anexar_comprovante(
    request: Request,
    gasto_id: int,
    imagem: UploadFile = File(...),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    conteudo, mime = await _ler_arquivo(imagem, permitir_pdf=True)

    return await run_in_threadpool(
        gasto_service.anexar_comprovante, db, gasto_id, conteudo, mime, user_id
    )


@router.delete("/gastos/{gasto_id}/comprovante", response_model=GastoResponse)
@limiter.limit("30/minute")
def remover_comprovante(request: Request, gasto_id: int, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return gasto_service.remover_comprovante(db, gasto_id, user_id)
