from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from dependencies import get_current_user_id
from dtos.ciclo import CicloResponse, CicloRequest
from services import ciclo_service

router = APIRouter()


@router.post("/ciclos", response_model=CicloResponse)
def criar_ciclo(ciclo: CicloRequest, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return ciclo_service.criar_ciclo(db, ciclo, user_id)


@router.get("/usuario/ciclos", response_model=list[CicloResponse])
def get_all_ciclos(db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return ciclo_service.get_all_ciclos(db, user_id)


@router.get("/usuario/ciclos/resumo", response_model=list[CicloResponse])
def get_ciclos_resumo(db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return ciclo_service.get_ciclos_resumo(db, user_id)


@router.get("/ciclos/{ciclo_id}", response_model=CicloResponse)
def get_ciclo(ciclo_id: int, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return ciclo_service.get_user_ciclo_by_id(db, ciclo_id, user_id)


@router.delete("/ciclos/{ciclo_id}")
def delete_ciclo(ciclo_id: int, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    ciclo_service.delete_ciclo(db, ciclo_id, user_id)
    return None
    

@router.put("/ciclos/{ciclo_id}", response_model=CicloResponse)
def update_ciclo(ciclo_id: int, ciclo_request: CicloRequest, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return ciclo_service.update_ciclo(db, ciclo_id, user_id, ciclo_request)
