from pydantic import BaseModel

from enums.categoria_enum import Categoria


class GastoResponse(BaseModel):
    id: int
    titulo: str
    valor: float
    categoria: Categoria

    class Config:
        from_attributes = True