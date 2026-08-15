from typing import Optional

from pydantic import BaseModel

from enums.categoria_enum import Categoria


class GastoResponse(BaseModel):
    id: int
    client_id: Optional[str] = None
    titulo: str
    valor: float
    categoria: Categoria
    comprovante_url: Optional[str] = None

    class Config:
        from_attributes = True
