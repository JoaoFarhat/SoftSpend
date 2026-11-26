from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator, model_validator
from typing import List
from datetime import datetime, date, timezone
from dtos.gasto.gasto_response import GastoResponse
from dtos.tipos import Dinheiro
from services.dia_calendario import dia_de_calendario


class DiaResponse(BaseModel):
    id: int
    client_id: str | None
    data: datetime
    data_local: date | None = Field(
        default=None, validation_alias=AliasChoices("data_local", "data_dia")
    )
    saldo: Dinheiro
    gastos: List[GastoResponse]

    @field_validator("data", mode="before")
    def ensure_utc(cls, v):
        if isinstance(v, date) and not isinstance(v, datetime):
            return datetime.combine(v, datetime.min.time(), tzinfo=timezone.utc)

        if isinstance(v, datetime):
            if v.tzinfo is None:
                return v.replace(tzinfo=timezone.utc)

        return v

    @model_validator(mode="after")
    def preencher_data_local(self):
        # Linha com `data_dia` nulo (anterior ao backfill): mesmo fallback
        # pela hora UTC que o servidor usa ao receber um app antigo.
        if self.data_local is None and self.data is not None:
            self.data_local = dia_de_calendario(self.data)
        return self

    model_config = ConfigDict(from_attributes=True)
