"""Data de calendário do dia da viagem (spec `docs/data-do-dia.md`).

`dias.data` é um instante (a meia-noite local do aparelho gravada em UTC), e
ler o dia de calendário dele em UTC erra em um dia para todo fuso a leste de
Greenwich. A coluna `dias.data_dia` guarda o dia de calendário (`YYYY-MM-DD`)
enviado pelo app em `data_local`; para linhas antigas (ou apps antigos, que
não mandam `data_local`) a heurística de `dia_de_calendario` recupera o dia a
partir da hora UTC do instante.
"""

from datetime import date, datetime, timedelta, timezone
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import models

# Corte da heurística: hora UTC ≥ 11 é meia-noite num fuso a leste de
# Greenwich (Paris às 22:00Z, Nova Zelândia às 11:00Z) e o dia certo é o dia
# UTC seguinte; abaixo disso (00:00Z, Brasil às 03:00Z, Havaí às 10:00Z) é o
# próprio dia UTC. A faixa 10:00Z–12:00Z é ambígua (Samoa vs. Tonga); a regra
# escolhe a leste a partir das 11h — os fusos a leste pesam mais.
_HORA_CORTE_UTC = 11


def dia_de_calendario(instante: datetime) -> date:
    """Dia de calendário aproximado a partir do instante guardado em UTC."""
    if instante.tzinfo is not None:
        instante = instante.astimezone(timezone.utc)
    dia_utc = instante.date()
    if instante.hour >= _HORA_CORTE_UTC:
        return dia_utc + timedelta(days=1)
    return dia_utc


def data_do_dia(dia: "models.Dia") -> date | None:
    """`data_dia` gravada ou, em linha antiga, o fallback pelo instante."""
    if dia is None:
        return None
    if dia.data_dia is not None:
        return dia.data_dia
    if dia.data is None:
        return None
    return dia_de_calendario(dia.data)
