from datetime import date
from typing import Literal

from pydantic import BaseModel

from dtos.tipos import Dinheiro
from enums.categoria_enum import Categoria


class MatchPrevia(BaseModel):
    gasto_id: int
    score: int
    status: str


class CompraLida(BaseModel):
    indice: int
    data: date
    descricao: str
    valor: Dinheiro
    parcela_atual: int | None = None
    parcela_total: int | None = None
    tipo: Literal["COMPRA", "ESTORNO", "ENCARGO"] = "COMPRA"
    categoria: Categoria = Categoria.OUTROS
    valor_original: str | None = None
    dentro_da_viagem: bool = False
    dia_id: int | None = None
    match: MatchPrevia | None = None


class FaturaLida(BaseModel):
    emissor: str | None = None
    final_cartao: str | None = None
    fechamento: date | None = None
    vencimento: date | None = None
    total_fatura: Dinheiro | None = None
    moeda: str = "BRL"
    soma_confere: bool | None = None
    diferenca: Dinheiro | None = None
    avisos: list[str] = []
    compras: list[CompraLida] = []
