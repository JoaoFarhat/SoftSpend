from datetime import datetime

from pydantic import BaseModel


class AssinaturaResponse(BaseModel):
    status: str
    tem_acesso: bool
    expira_em: datetime | None = None
    produto: str | None = None
    app_account_token: str
