"""Timeout do proxy do nginx para pedidos longos.

A leitura da fatura em PDF pelo Gemini pode levar ~2 min (TIMEOUT_MS de 60 s
com HttpRetryOptions attempts=2) e o relatório em PDF com muitas notas também
passa de 1 min, enquanto o app espera até 300 s (uploadSession). Sem
proxy_read_timeout o nginx usa o default de 60 s e responde 504 enquanto o
uvicorn ainda processa — e a fatura gasta a vaga do dia da IA mesmo assim.

Este arquivo garante que o bloco da porta 443 de
deploy/ec2/nginx-softspend.conf define proxy_read_timeout e
proxy_send_timeout acima do pior caso da fatura e abaixo do teto do app, e
que a config HTTP provisória do deploy/ec2/setup.sh tem as mesmas linhas.
"""

import re
from pathlib import Path

import pytest

from services import fatura_ia_service

RAIZ = Path(__file__).resolve().parents[2]
NGINX_CONF = RAIZ / "deploy" / "ec2" / "nginx-softspend.conf"
SETUP_SH = RAIZ / "deploy" / "ec2" / "setup.sh"

# Piso: a fatura pode esperar 2 tentativas de TIMEOUT_MS (+ retry) — o nginx
# precisa passar disso com folga. Teto: os 300 s da uploadSession do app.
PISO_S = 2 * fatura_ia_service.TIMEOUT_MS / 1000 + 10
TETO_S = 300


def _segundos(bloco: str, diretiva: str) -> int:
    casou = re.search(rf"{diretiva}\s+(\d+)s\s*;", bloco)
    assert casou, f"{diretiva} ausente ou sem sufixo 's' no bloco da porta 443"
    return int(casou.group(1))


@pytest.mark.parametrize("diretiva", ("proxy_read_timeout", "proxy_send_timeout"))
def test_bloco_443_timeout_entre_piso_e_teto(diretiva):
    conf = NGINX_CONF.read_text(encoding="utf-8")
    bloco_443 = conf.split("listen 443", 1)[1]
    segundos = _segundos(bloco_443, diretiva)
    assert PISO_S <= segundos < TETO_S


@pytest.mark.parametrize("diretiva", ("proxy_read_timeout", "proxy_send_timeout"))
def test_setup_http_provisorio_tem_timeout(diretiva):
    setup = SETUP_SH.read_text(encoding="utf-8")
    assert re.search(rf"{diretiva}\s+\d+s\s*;", setup)
