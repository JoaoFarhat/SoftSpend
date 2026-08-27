from pydantic import BaseModel

from enums.categoria_enum import Categoria
from dtos.tipos import Dinheiro


class GastoExtraidoResponse(BaseModel):
    titulo: str
    valor: Dinheiro
    categoria: Categoria
