from typing import Optional
from pydantic import BaseModel, Field, field_validator

class CicloRequest(BaseModel):
    client_id: Optional[str] = Field(default=None, max_length=50)
    valor_total: float = Field(..., gt=0)
    periodo: str = Field(..., min_length=1, max_length=100)
    diaria: float = Field(..., gt=0)
    titulo: str = Field(..., min_length=1, max_length=100)

    @field_validator("periodo", "titulo")
    @classmethod
    def nao_somente_espacos(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Campo nao pode conter apenas espacos")
        return v.strip()