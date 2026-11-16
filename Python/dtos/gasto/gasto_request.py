from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, Field, field_validator

from enums.categoria_enum import Categoria
from dtos.tipos import validador_monetario


class GastoRequest(BaseModel):
    client_id: Optional[str] = Field(default=None, max_length=50)
    titulo: str = Field(..., min_length=1, max_length=100)
    valor: Decimal = Field(..., gt=0, max_digits=10, decimal_places=2)
    categoria: Categoria
    dia_id: Optional[int] = Field(default=None, gt=0)

    _arredondar = validador_monetario("valor")

    @field_validator("titulo")
    @classmethod
    def nao_somente_espacos(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Campo nao pode conter apenas espacos")
        return v.strip()
