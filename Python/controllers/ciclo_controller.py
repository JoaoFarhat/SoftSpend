from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Request, Query
from fastapi.responses import Response
from sqlalchemy.orm import Session
from database import get_db
from dependencies import get_current_user_id
from dtos.ciclo import CicloResponse, CicloRequest
from services import ciclo_service, export_service
from limiter import limiter

router = APIRouter()


@router.post("/ciclos", response_model=CicloResponse)
@limiter.limit("20/minute")
def criar_ciclo(request: Request, ciclo: CicloRequest, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return ciclo_service.criar_ciclo(db, ciclo, user_id)


@router.get("/usuario/ciclos", response_model=list[CicloResponse])
@limiter.limit("60/minute")
def get_all_ciclos(
    request: Request,
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=1000),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    return ciclo_service.get_all_ciclos(db, user_id, skip=skip, limit=limit)


@router.get("/usuario/ciclos/resumo", response_model=list[CicloResponse])
@limiter.limit("60/minute")
def get_ciclos_resumo(
    request: Request,
    skip: int = Query(0, ge=0),
    limit: int = Query(1000, ge=1, le=1000),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    return ciclo_service.get_ciclos_resumo(db, user_id, skip=skip, limit=limit)


@router.get("/ciclos/{ciclo_id}", response_model=CicloResponse)
@limiter.limit("60/minute")
def get_ciclo(request: Request, ciclo_id: int, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return ciclo_service.get_user_ciclo_by_id(db, ciclo_id, user_id)


@router.get("/ciclos/{ciclo_id}/export")
# Gerar PDF com comprovantes envolve varios downloads do bucket; limite mais
# apertado que as leituras normais.
@limiter.limit("10/minute")
def exportar_ciclo(
    request: Request,
    ciclo_id: int,
    formato: str = Query("pdf", pattern="^(pdf|csv)$"),
    comprovantes: str = Query("imagem", pattern="^(imagem|link|nenhum)$"),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """Relatorio dos gastos do ciclo.

    Handler sincrono de proposito: boto3, Pillow e ReportLab sao bloqueantes,
    entao o FastAPI executa isso no threadpool. Como `async def`, uma exportacao
    longa travaria o event loop e, com ele, a API inteira.
    """
    ciclo = ciclo_service.get_user_ciclo_by_id(db, ciclo_id, user_id)
    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    if formato == "csv":
        conteudo = export_service.gerar_csv(ciclo)
        media_type = "text/csv; charset=utf-8"
    else:
        conteudo = export_service.gerar_pdf(ciclo, comprovantes=comprovantes)
        media_type = "application/pdf"

    nome = export_service.nome_arquivo(ciclo, formato)

    return Response(
        content=conteudo,
        media_type=media_type,
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(nome)}",
            "Content-Length": str(len(conteudo)),
        },
    )


@router.delete("/ciclos/{ciclo_id}", status_code=204)
@limiter.limit("20/minute")
def delete_ciclo(request: Request, ciclo_id: int, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    ciclo_service.delete_ciclo(db, ciclo_id, user_id)
    return None
    

@router.put("/ciclos/{ciclo_id}", response_model=CicloResponse)
@limiter.limit("20/minute")
def update_ciclo(request: Request, ciclo_id: int, ciclo_request: CicloRequest, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return ciclo_service.update_ciclo(db, ciclo_id, user_id, ciclo_request)
