from typing import Optional

from pydantic import BaseModel, ConfigDict

from enums.categoria_enum import Categoria
from dtos.open_finance import ExpenseTransactionMatchResponse
from dtos.tipos import Dinheiro


class GastoResponse(BaseModel):
    id: int
    client_id: Optional[str] = None
    titulo: str
    valor: Dinheiro
    categoria: Categoria
    comprovante_url: Optional[str] = None
    open_finance_status: str = "PENDENTE"
    open_finance_match: Optional[ExpenseTransactionMatchResponse] = None

    model_config = ConfigDict(from_attributes=True)
