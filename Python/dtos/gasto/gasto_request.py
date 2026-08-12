from typing import Optional

from pydantic import BaseModel

from enums.categoria_enum import Categoria

class GastoRequest(BaseModel):
    titulo: str
    valor: float
    categoria: Categoria
    dia_id: Optional[int] = None