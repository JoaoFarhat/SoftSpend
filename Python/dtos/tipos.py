from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Annotated

from pydantic import PlainSerializer, field_validator


def arredondar_monetario(v) -> Decimal:
    """Converte um valor para Decimal monetário (2 casas decimais).

    Levanta ValueError para entradas inválidas, permitindo que o Pydantic
    vire um erro de validação HTTP 422 em vez de um 500.
    """
    try:
        d = v if isinstance(v, Decimal) else Decimal(str(v))
        if not d.is_finite():
            raise ValueError("Valor monetário inválido")
        return d.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    except Exception as exc:
        raise ValueError("Valor monetário inválido") from exc


# Decimal que serializa como número JSON (float) para compatibilidade com o
# app iOS, que decodifica os campos monetários como Decimal a partir de números.
Dinheiro = Annotated[
    Decimal,
    PlainSerializer(lambda v: float(v), return_type=float, when_used="json"),
]


def validador_monetario(*campos: str):
    """Cria um field_validator 'before' para campos monetários."""

    @field_validator(*campos, mode="before")
    @classmethod
    def _validar(cls, v):
        return arredondar_monetario(v)

    return _validar
