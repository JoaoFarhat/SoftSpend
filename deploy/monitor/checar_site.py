#!/usr/bin/env python3
"""Monitor do site (docs/publicacao.md §3, linhas Disponibilidade e HTTPS).

Roda no GitHub Actions (.github/workflows/monitor.yml) a cada 30 minutos:

- `GET https://<host>/health` com timeout de 10 s, até 2 tentativas com
  30 s entre elas, para não alarmar por um soluço;
- certificado TLS da porta 443 com pelo menos 14 dias de validade.

Imprime uma linha por checagem e sai 0 (tudo certo) ou 1 (alguma falhou);
o GitHub manda e-mail ao dono quando o workflow agendado falha. Só usa a
biblioteca padrão e nenhum segredo.

`avaliar_health` e `dias_ate_vencer` são puras; `checar_health` e
`checar_certificado` recebem a rede por parâmetro, então os testes rodam
sem rede (`Python/tests/test_checar_site.py`).
"""

from __future__ import annotations

import argparse
import json
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Callable

HOST_PADRAO = "softspend.com.br"
TIMEOUT_S = 10
TENTATIVAS = 2
ESPERA_ENTRE_TENTATIVAS_S = 30
DIAS_MINIMOS_CERTIFICADO = 14

FORMATO_NOT_AFTER = "%b %d %H:%M:%S %Y GMT"


def avaliar_health(status: int, corpo: bytes) -> str | None:
    """Motivo da falha, ou None se o status é 200 e o JSON é {"status": "ok"}."""
    if status != 200:
        return f"HTTP {status}"
    try:
        dados = json.loads(corpo)
    except (UnicodeDecodeError, ValueError):
        return "corpo não é JSON válido"
    if dados != {"status": "ok"}:
        return f"corpo inesperado: {corpo[:200]!r}"
    return None


def dias_ate_vencer(not_after: str, agora: datetime) -> int:
    """Dias inteiros até o vencimento (formato do getpeercert()['notAfter'])."""
    vencimento = datetime.strptime(not_after, FORMATO_NOT_AFTER).replace(
        tzinfo=timezone.utc
    )
    if agora.tzinfo is None:
        agora = agora.replace(tzinfo=timezone.utc)
    return (vencimento - agora).days


# ---------------------------------------------------------------------------
# Rede (substituída por falso nos testes)
# ---------------------------------------------------------------------------


def buscar_health(host: str, timeout: float = TIMEOUT_S) -> tuple[int, bytes]:
    """GET https://<host>/health; devolve (status, corpo)."""
    req = urllib.request.Request(
        f"https://{host}/health",
        headers={"User-Agent": "softspend-monitor"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def not_after_certificado(
    host: str, porta: int = 443, timeout: float = TIMEOUT_S
) -> str:
    """Lê o notAfter do certificado TLS do host."""
    ctx = ssl.create_default_context()
    with socket.create_connection((host, porta), timeout=timeout) as tcp:
        with ctx.wrap_socket(tcp, server_hostname=host) as tls:
            return tls.getpeercert()["notAfter"]


# ---------------------------------------------------------------------------
# Checagens
# ---------------------------------------------------------------------------


def checar_health(
    host: str,
    *,
    tentativas: int = TENTATIVAS,
    espera: float = ESPERA_ENTRE_TENTATIVAS_S,
    buscar: Callable[[str, float], tuple[int, bytes]] | None = None,
    dormir: Callable[[float], None] = time.sleep,
) -> str | None:
    """Motivo da falha após as tentativas, ou None."""
    buscar = buscar or buscar_health
    motivo = "sem tentativa"
    for n in range(1, tentativas + 1):
        try:
            motivo = avaliar_health(*buscar(host, TIMEOUT_S))
        except Exception as e:
            motivo = f"erro de rede: {e}"
        if motivo is None:
            return None
        if n < tentativas:
            dormir(espera)
    return motivo


def checar_certificado(
    host: str,
    *,
    agora: datetime | None = None,
    ler_not_after: Callable[[str], str] | None = None,
) -> str | None:
    """Motivo da falha, ou None se faltam 14 dias ou mais para vencer."""
    ler = ler_not_after or not_after_certificado
    agora = agora or datetime.now(timezone.utc)
    try:
        not_after = ler(host)
    except Exception as e:
        return f"erro ao ler certificado: {e}"
    try:
        dias = dias_ate_vencer(not_after, agora)
    except ValueError:
        return f"notAfter em formato inesperado: {not_after!r}"
    if dias < DIAS_MINIMOS_CERTIFICADO:
        return f"certificado vence em {dias} dias ({not_after})"
    return None


def main(
    argv: list[str] | None = None,
    *,
    checar_h: Callable[..., str | None] | None = None,
    checar_c: Callable[..., str | None] | None = None,
) -> int:
    parser = argparse.ArgumentParser(
        description="Checa /health e o certificado TLS do site."
    )
    parser.add_argument("host", nargs="?", default=HOST_PADRAO)
    args = parser.parse_args(argv)
    checar_h = checar_h or checar_health
    checar_c = checar_c or checar_certificado

    falhas = 0
    url = f"https://{args.host}/health"
    motivo = checar_h(args.host)
    if motivo is None:
        print(f"{url}: ok")
    else:
        print(f"{url}: FALHOU — {motivo}")
        falhas += 1

    motivo = checar_c(args.host)
    if motivo is None:
        print(f"certificado {args.host}:443: ok")
    else:
        print(f"certificado {args.host}:443: FALHOU — {motivo}")
        falhas += 1

    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
