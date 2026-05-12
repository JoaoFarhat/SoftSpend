from pydantic import BaseModel
from typing import List
from dtos.dia.dia_response import DiaResponse

class CicloResponse(BaseModel):
    id: int
    valor_total: float
    gasto_total: float
    diaria: float
    titulo: str
    periodo: str
    dias: List[DiaResponse]

    class Config:
        from_attributes = True