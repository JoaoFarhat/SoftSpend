from typing import Optional

from pydantic import BaseModel, Field

from enums.categoria_enum import Categoria

class GastoRequest(BaseModel):
    titulo: str = Field(..., min_length=1, max_length=100)
    valor: float = Field(..., gt=0)
    categoria: Categoria
    dia_id: Optional[int] = Field(default=None, gt=0)