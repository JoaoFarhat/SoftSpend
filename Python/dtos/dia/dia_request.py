from typing import Optional
from datetime import datetime, date, timezone, timedelta
from pydantic import BaseModel, Field, field_validator

class DiaRequest(BaseModel):
    client_id: Optional[str] = Field(default=None, max_length=50)
    data: datetime
    data_local: Optional[date] = None

    @field_validator("data")
    @classmethod
    def data_dentro_do_limite(cls, v: datetime) -> datetime:
        if isinstance(v, date) and not isinstance(v, datetime):
            v = datetime.combine(v, datetime.min.time())

        if v.tzinfo is None:
            v = v.replace(tzinfo=timezone.utc)

        agora = datetime.now(timezone.utc)
        limite = timedelta(days=365 * 5)
        if v < agora - limite or v > agora + limite:
            raise ValueError("Data fora do intervalo aceito")

        return v

    @field_validator("data_local")
    @classmethod
    def data_local_dentro_do_limite(cls, v: Optional[date]) -> Optional[date]:
        if v is None:
            return v

        hoje = datetime.now(timezone.utc).date()
        limite = timedelta(days=365 * 5)
        if v < hoje - limite or v > hoje + limite:
            raise ValueError("Data fora do intervalo aceito")

        return v