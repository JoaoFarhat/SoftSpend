from datetime import date
from typing import Annotated, Literal

from pydantic import BaseModel, Field

from dtos.tipos import Dinheiro
from enums.categoria_enum import Categoria

# Teto de compras por fatura. Fica no DTO (e não em fatura_arquivo_service)
# porque o Pydantic precisa dele para recusar o corpo na borda, antes de
# montar a lista inteira; `gravar_fatura` confere de novo por defesa.
MAXIMO_COMPRAS = 200


class MatchPrevia(BaseModel):
    gasto_id: int
    score: int
    status: str


class CompraLida(BaseModel):
    indice: int
    data: date
    descricao: str = Field(max_length=500)
    valor: Dinheiro
    parcela_atual: int | None = None
    parcela_total: int | None = None
    tipo: Literal["COMPRA", "ESTORNO", "ENCARGO"] = "COMPRA"
    categoria: Categoria = Categoria.OUTROS
    valor_original: str | None = Field(default=None, max_length=100)
    dentro_da_viagem: bool = False
    dia_id: int | None = None
    match: MatchPrevia | None = None


class FaturaLida(BaseModel):
    emissor: str | None = Field(default=None, max_length=255)
    final_cartao: str | None = Field(default=None, max_length=20)
    fechamento: date | None = None
    vencimento: date | None = None
    total_fatura: Dinheiro | None = None
    moeda: str = Field(default="BRL", max_length=10)
    soma_confere: bool | None = None
    diferenca: Dinheiro | None = None
    # Sem teto de itens: o OFX gera um aviso por lançamento ilegível.
    avisos: list[Annotated[str, Field(max_length=500)]] = Field(default_factory=list)
    compras: list[CompraLida] = Field(default_factory=list, max_length=MAXIMO_COMPRAS)
