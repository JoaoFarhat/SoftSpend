from fastapi import APIRouter, Depends, HTTPException, Request, Query
from sqlalchemy.orm import Session
from database import get_db
from dependencies import get_current_user_id
from dtos.ciclo import CicloResponse, CicloRequest
from services import ciclo_service
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


@router.delete("/ciclos/{ciclo_id}", status_code=204)
@limiter.limit("20/minute")
def delete_ciclo(request: Request, ciclo_id: int, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    ciclo_service.delete_ciclo(db, ciclo_id, user_id)
    return None
    

@router.put("/ciclos/{ciclo_id}", response_model=CicloResponse)
@limiter.limit("20/minute")
def update_ciclo(request: Request, ciclo_id: int, ciclo_request: CicloRequest, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)):
    return ciclo_service.update_ciclo(db, ciclo_id, user_id, ciclo_request)
