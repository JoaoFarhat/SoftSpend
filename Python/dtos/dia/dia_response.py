from pydantic import BaseModel, field_validator
from typing import List
from datetime import datetime, date, timezone
from dtos.gasto.gasto_response import GastoResponse

class DiaResponse(BaseModel):
    id: int
    data: datetime
    saldo: float
    gastos: List[GastoResponse]

    @field_validator("data", mode="before")
    def ensure_utc(cls, v):
        if isinstance(v, date) and not isinstance(v, datetime):
            return datetime.combine(v, datetime.min.time(), tzinfo=timezone.utc)

        if isinstance(v, datetime):
            if v.tzinfo is None:
                return v.replace(tzinfo=timezone.utc)

        return v

    class Config:
        from_attributes = True

