from datetime import datetime

from pydantic import BaseModel, Field


class TransacaoRequest(BaseModel):
    # `jwsRepresentation` da transação no StoreKit 2.
    jws: str = Field(min_length=1, max_length=20000)


class AssinaturaResponse(BaseModel):
    status: str
    tem_acesso: bool
    expira_em: datetime | None = None
    produto: str | None = None
    app_account_token: str
