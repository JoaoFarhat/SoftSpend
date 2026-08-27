from decimal import Decimal
from typing import Optional
from pydantic import BaseModel, Field, field_validator

from dtos.tipos import arredondar_monetario, validador_monetario


class CicloRequest(BaseModel):
    client_id: Optional[str] = Field(default=None, max_length=50)
    valor_total: Decimal = Field(..., gt=0, max_digits=10, decimal_places=2)
    periodo: str = Field(..., min_length=1, max_length=100)
    diaria: Decimal = Field(..., gt=0, max_digits=10, decimal_places=2)
    titulo: str = Field(..., min_length=1, max_length=100)

    _arredondar = validador_monetario("valor_total", "diaria")

    @field_validator("periodo", "titulo")
    @classmethod
    def nao_somente_espacos(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Campo nao pode conter apenas espacos")
        return v.strip()
