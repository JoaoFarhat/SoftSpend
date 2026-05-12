from pydantic import BaseModel

from enums.categoria_enum import Categoria

class GastoRequest(BaseModel):
    titulo: str
    valor: float
    categoria: Categoria