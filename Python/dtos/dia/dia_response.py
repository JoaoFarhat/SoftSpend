from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator, model_validator
from typing import List, Optional
from datetime import datetime, date, timezone
from dtos.gasto.gasto_response import GastoResponse
from dtos.tipos import Dinheiro
from services.dia_calendario import dia_de_calendario


class DiaResponse(BaseModel):
    id: int
    client_id: str | None
    data: datetime
    # Na saída é "data_local"; no ORM o atributo é `data_dia`. Linha antiga
    # sem `data_dia` cai na heurística do `data` (spec docs/data-do-dia.md).
    data_local: Optional[date] = Field(
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
    def data_local_do_dia(self):
        if self.data_local is None:
            self.data_local = dia_de_calendario(self.data)
        return self

    model_config = ConfigDict(from_attributes=True)


