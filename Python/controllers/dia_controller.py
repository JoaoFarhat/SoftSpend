from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session
from typing import List
from database import get_db
from dependencies import get_current_user_id
from dtos.dia import DiaRequest, DiaResponse
from services import dia_service
from limiter import limiter

router = APIRouter()

@router.post("/ciclos/{ciclo_id}/dias", response_model=DiaResponse)
@limiter.limit("30/minute")
def criar_dia(request: Request, ciclo_id: int, dia: DiaRequest, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return dia_service.criar_dia(db, ciclo_id, dia, user_id)


@router.post("/ciclos/{ciclo_id}/dias/lote", response_model=List[DiaResponse])
@limiter.limit("30/minute")
def criar_dias_lote(request: Request, ciclo_id: int, dias: List[DiaRequest], db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return dia_service.criar_dias_lote(db, ciclo_id, dias, user_id)


@router.put("/ciclos/{ciclo_id}/dias/lote", response_model=List[DiaResponse])
@limiter.limit("30/minute")
def sincronizar_dias_lote(request: Request, ciclo_id: int, dias: List[DiaRequest], db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return dia_service.sincronizar_dias_lote(db, ciclo_id, dias, user_id)


@router.put("/dias/{dia_id}", response_model=DiaResponse)
@limiter.limit("30/minute")
def atualizar_dia(request: Request, dia_id: int, dia: DiaRequest, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return dia_service.atualizar_dia(db, dia_id, dia, user_id)


@router.delete("/dias/{dia_id}", status_code=204)
@limiter.limit("20/minute")
def remover_dia(request: Request, dia_id: int, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return dia_service.remover_dia(db, dia_id, user_id)
