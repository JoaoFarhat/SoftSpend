from pydantic import BaseModel
from typing import List
from dtos.dia.dia_request import DiaRequest

class CicloRequest(BaseModel):
    valor_total: float
    periodo: str
    diaria: float
    titulo: str
    dias: List[DiaRequest]