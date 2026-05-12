from enum import Enum

class Categoria(str, Enum):
    ALIMENTACAO = "ALIMENTACAO"
    TRANSPORTE = "TRANSPORTE"
    LAZER = "LAZER"
    COMPRAS = "COMPRAS"
    OUTROS = "OUTROS"