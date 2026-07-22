from pydantic import BaseModel

class CicloRequest(BaseModel):
    valor_total: float
    periodo: str
    diaria: float
    titulo: str