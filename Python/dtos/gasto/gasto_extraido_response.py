from pydantic import BaseModel

from enums.categoria_enum import Categoria


class GastoExtraidoResponse(BaseModel):
    titulo: str
    valor: float
    categoria: Categoria
