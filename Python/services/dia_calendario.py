"""O dia da viagem como data de calendário (spec `docs/data-do-dia.md` §§3-4).

`dias.data` guarda a meia-noite local do aparelho como instante UTC; ler
`.date()` em UTC erra um dia nos fusos a leste de Greenwich. A coluna
`dias.data_dia` (`Date`) passa a guardar o dia de calendário: preenchida pelo
`data_local` que o app novo manda, ou pela heurística do §4 para o app antigo
e para as linhas já gravadas.
"""

from datetime import date, datetime, timedelta, timezone

import models

# A hora UTC da meia-noite local revela o deslocamento (sempre inteira ou
# meia hora): >= 11 só pode ser fuso a leste de Greenwich (o dia local é o
# dia UTC seguinte); < 11 cobre UTC-10 (Havaí) até UTC-3 (Brasil) e o próprio
# UTC. A ambiguidade 10h-12h (Samoa/Niue x Nova Zelândia/Tonga) é resolvida
# para o leste — o §4 da spec explica a escolha.
HORA_CORTE_UTC = 11


def dia_de_calendario(instante: datetime) -> date:
    """Dia de calendário que o aparelho quis dizer com a meia-noite local.

    `instante` é o `dias.data`: o banco grava em UTC sem fuso, mas um valor
    com `tzinfo` é normalizado para UTC antes de ler a hora.
    """
    if instante.tzinfo is not None:
        instante = instante.astimezone(timezone.utc)
    dia = instante.date()
    if instante.hour >= HORA_CORTE_UTC:
        dia += timedelta(days=1)
    return dia


def data_do_dia(dia: models.Dia) -> date | None:
    """`dias.data_dia`; linha sem ele cai na heurística sobre `dias.data`."""
    if dia.data_dia is not None:
        return dia.data_dia
    if dia.data is None:
        return None
    return dia_de_calendario(dia.data)
