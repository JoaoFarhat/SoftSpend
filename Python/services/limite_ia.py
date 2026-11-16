"""Teto diário de leituras por IA por usuário (`docs/publicacao.md` §3).

Contador em memória por (usuário, tipo, data UTC), protegido por
`threading.Lock`: o uvicorn roda num processo só e reiniciar zera a
contagem — aceito por enquanto (o slowapi continua limitando por minuto e
por IP). Cobre só as rotas que chamam o Gemini: `POST /gastos/extrair`
(tipo `comprovante`) e `POST /api/faturas/ler` com PDF (tipo `fatura`; OFX
e CSV não passam por IA e não contam).

`devolver` desfaz uma contagem quando a chamada ao Gemini não teve resposta
(fora do ar, sem chave): a vaga do dia só fica gasta quando a IA respondeu.
"""

import os
import threading
from datetime import date, datetime, timezone

from fastapi import HTTPException

COMPROVANTE = "comprovante"
FATURA = "fatura"

_TETOS = {
    COMPROVANTE: ("IA_LIMITE_DIARIO_COMPROVANTE", 60),
    FATURA: ("IA_LIMITE_DIARIO_FATURA", 10),
}

_lock = threading.Lock()
_contadores: dict[tuple[str, str, date], int] = {}


def _teto(tipo: str) -> int:
    """Teto do tipo, lido da variável a cada chamada. `0` desliga."""
    variavel, padrao = _TETOS[tipo]
    try:
        return int(os.getenv(variavel, str(padrao)))
    except ValueError:
        return padrao


def _hoje() -> date:
    return datetime.now(timezone.utc).date()


def contar(user_id: str, tipo: str, hoje: date | None = None) -> date:
    """Conta uma leitura de IA do usuário; estourado, responde 429.

    O pedido recusado não gasta cota: o contador só sobe quando ainda há
    vaga. `hoje` existe para o teste injetar outra data UTC.

    Devolve a data UTC usada na chave: quem chama `devolver` repassa essa
    data para a devolução cair no mesmo dia mesmo se a virada UTC
    acontecer no meio da chamada.
    """
    dia = hoje or _hoje()
    teto = _teto(tipo)
    if teto <= 0:
        return dia

    chave = (user_id, tipo, dia)
    with _lock:
        # Descarta os dias anteriores para a memória não crescer num
        # servidor que fica semanas no ar.
        for k in list(_contadores):
            if k[2] != dia:
                del _contadores[k]
        usado = _contadores.get(chave, 0)
        if usado >= teto:
            raise HTTPException(status_code=429, detail="daily_ai_limit")
        _contadores[chave] = usado + 1
    return dia


def devolver(user_id: str, tipo: str, hoje: date | None = None) -> None:
    """Devolve uma leitura cuja chamada à IA não teve resposta.

    Desce 1 na mesma chave do dia usada pelo `contar`, nunca abaixo de 0.
    Com o teto desligado (`0`) o `contar` não contou nada, então não há o
    que devolver.
    """
    if _teto(tipo) <= 0:
        return

    chave = (user_id, tipo, hoje or _hoje())
    with _lock:
        usado = _contadores.get(chave, 0)
        if usado > 0:
            _contadores[chave] = usado - 1
