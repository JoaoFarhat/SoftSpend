from typing import List
from pydantic import BaseModel
from dtos.dia.dia_response import DiaResponse
from dtos.tipos import Dinheiro


class CicloResponse(BaseModel):
    id: int
    client_id: str | None
    valor_total: Dinheiro
    gasto_total: Dinheiro
    diaria: Dinheiro
    titulo: str
    periodo: str
    dias: List[DiaResponse]

    class Config:
        from_attributes = True
