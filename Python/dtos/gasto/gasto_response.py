from typing import Optional

from pydantic import BaseModel, ConfigDict

from enums.categoria_enum import Categoria
from dtos.tipos import Dinheiro


class GastoResponse(BaseModel):
    id: int
    client_id: Optional[str] = None
    titulo: str
    valor: Dinheiro
    categoria: Categoria
    comprovante_url: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)
