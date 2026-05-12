from fastapi import APIRouter, Depends, UploadFile, File, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from dependencies import get_current_user_id
from dtos.gasto import GastoResponse, GastoRequest, GastoExtraidoResponse
from services import gasto_service, ocr_service

router = APIRouter()

@router.post("/dias/{dia_id}/gastos", response_model=GastoResponse)
def criar_gasto(dia_id: int, gasto: GastoRequest, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return gasto_service.criar_gasto(db, dia_id, gasto, user_id)

@router.delete("/gastos/{gasto_id}", status_code = 204)
def deletar_gasto(gasto_id: int, db: Session = Depends(get_db), user_id: int = Depends(get_current_user_id)):
    return gasto_service.remover_gasto(db, gasto_id, user_id)

@router.post("/gastos/extrair", response_model=GastoExtraidoResponse)
async def extrair_gasto_de_imagem(imagem: UploadFile = File(...), user_id: int = Depends(get_current_user_id)):
    if not imagem.content_type or not imagem.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Arquivo deve ser uma imagem")
    
    conteudo = await imagem.read()
    
    if len(conteudo) > 10 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Imagem muito grande (max 10MB)")
    
    try:
        dados = ocr_service.extrair_gasto_da_imagem(conteudo)
        return dados
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erro ao processar imagem: {e}")