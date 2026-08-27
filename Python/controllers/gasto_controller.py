from fastapi import APIRouter, Depends, UploadFile, File, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from sqlalchemy.orm import Session
import filetype
from database import get_db
from dependencies import get_current_user_id
from dtos.gasto import GastoResponse, GastoRequest, GastoExtraidoResponse
from services import gasto_service, ocr_service
from limiter import limiter

router = APIRouter()

TAMANHO_MAXIMO_IMAGEM = 5 * 1024 * 1024


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


async def _ler_imagem(imagem: UploadFile) -> bytes:
    if not imagem.content_type or imagem.content_type not in MIME_TYPES_PERMITIDOS:
        raise HTTPException(status_code=400, detail="Arquivo deve ser uma imagem (JPEG, PNG ou WEBP)")

    # Aborta o mais cedo possível se o client declarar Content-Length
    if imagem.size is not None and imagem.size > TAMANHO_MAXIMO_IMAGEM:
        raise HTTPException(status_code=413, detail="Imagem muito grande (max 5MB)")

    # Lê em chunks para não carregar arquivos gigantes inteiros em memória/disco
    # caso o Content-Length esteja ausente ou seja mentiroso.
    conteudo = b""
    chunk_size = 64 * 1024
    while True:
        chunk = await imagem.read(chunk_size)
        if not chunk:
            break
        conteudo += chunk
        if len(conteudo) > TAMANHO_MAXIMO_IMAGEM:
            raise HTTPException(status_code=413, detail="Imagem muito grande (max 5MB)")

    kind = filetype.guess(conteudo)
    if kind is None or kind.mime not in MIME_TYPES_PERMITIDOS:
        raise HTTPException(status_code=400, detail="Conteúdo do arquivo não corresponde a uma imagem permitida")

    return conteudo


@router.post("/gastos/extrair", response_model=GastoExtraidoResponse)
@limiter.limit("20/minute")
async def extrair_gasto_de_imagem(request: Request, imagem: UploadFile = File(...), user_id: str = Depends(get_current_user_id)):
    conteudo = await _ler_imagem(imagem)

    try:
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
    conteudo = await _ler_imagem(imagem)

    return await run_in_threadpool(
        gasto_service.anexar_comprovante, db, gasto_id, conteudo, imagem.content_type, user_id
    )


@router.delete("/gastos/{gasto_id}/comprovante", response_model=GastoResponse)
@limiter.limit("30/minute")
def remover_comprovante(request: Request, gasto_id: int, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return gasto_service.remover_comprovante(db, gasto_id, user_id)
