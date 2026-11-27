"""Envio de e-mail transacional (hoje so o codigo do "Esqueci minha senha").

Sai pelo AWS SES (API v2). Fica desligado ate `EMAIL_REMETENTE` existir: sem
ele, `esta_configurado()` e falso e a rota de pedir codigo responde 503.

Variaveis (lidas a cada envio, para os testes poderem trocar):

- `EMAIL_REMETENTE` — obrigatoria; ex.: `SoftSpend <nao-responda@softspend.com.br>`.
  O dominio (ou o endereco) precisa estar verificado no SES.
- `SES_REGION` — regiao do SES (default `us-east-1`).
- `SES_ACCESS_KEY_ID` / `SES_SECRET_ACCESS_KEY` — opcionais; sem elas vale a
  cadeia padrao do boto3 (role da EC2, `~/.aws`).

O envio roda em background (BackgroundTasks) e nunca lanca: falha so vai para o
log, sem o e-mail do destinatario nem o codigo.
"""
import logging
from html import escape as html_escape
import os

import boto3

logger = logging.getLogger(__name__)


def esta_configurado() -> bool:
    return bool(os.getenv("EMAIL_REMETENTE", "").strip())


def _cliente():
    chave = os.getenv("SES_ACCESS_KEY_ID")
    segredo = os.getenv("SES_SECRET_ACCESS_KEY")
    credenciais = (
        {"aws_access_key_id": chave, "aws_secret_access_key": segredo}
        if chave and segredo
        else {}
    )
    return boto3.client(
        "sesv2", region_name=os.getenv("SES_REGION", "us-east-1"), **credenciais
    )


def _corpo_codigo(nome: str, codigo: str, minutos: int) -> tuple[str, str]:
    primeiro_nome = (nome or "").strip().split(" ")[0]
    saudacao = f"Olá, {primeiro_nome}" if primeiro_nome else "Olá"
    texto = (
        f"{saudacao}!\n\n"
        f"Seu código para criar uma senha nova no SoftSpend é: {codigo}\n\n"
        f"Ele vale por {minutos} minutos. Se não foi você que pediu, ignore este "
        "e-mail: sua senha continua a mesma.\n"
    )
    html = (
        f"<p>{html_escape(saudacao)}!</p>"
        "<p>Seu código para criar uma senha nova no SoftSpend é:</p>"
        f'<p style="font-size:28px;font-weight:bold;letter-spacing:6px">{codigo}</p>'
        f"<p>Ele vale por {minutos} minutos. Se não foi você que pediu, ignore este "
        "e-mail: sua senha continua a mesma.</p>"
    )
    return texto, html


def enviar_codigo_redefinicao(para: str, nome: str, codigo: str, minutos: int) -> None:
    remetente = os.getenv("EMAIL_REMETENTE", "").strip()
    if not remetente:
        logger.warning("E-mail de redefinicao nao enviado: EMAIL_REMETENTE ausente")
        return
    texto, html = _corpo_codigo(nome, codigo, minutos)
    try:
        _cliente().send_email(
            FromEmailAddress=remetente,
            Destination={"ToAddresses": [para]},
            Content={
                "Simple": {
                    "Subject": {"Data": "Seu código do SoftSpend", "Charset": "UTF-8"},
                    "Body": {
                        "Text": {"Data": texto, "Charset": "UTF-8"},
                        "Html": {"Data": html, "Charset": "UTF-8"},
                    },
                }
            },
        )
    except Exception as exc:  # noqa: BLE001 — background: so registra.
        logger.error("Falha ao enviar e-mail de redefinicao: %s", type(exc).__name__)
