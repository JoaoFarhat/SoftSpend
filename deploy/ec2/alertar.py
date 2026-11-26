#!/usr/bin/env python3
"""Aviso por e-mail quando uma unidade diária falha (docs/backup-mysql.md, §7).

O systemd chama este script pelo template `softspend-alerta@.service`, ligado
pelo `OnFailure=` do `softspend-backup.service` e do
`softspend-assinaturas.service`; o nome da unidade que falhou vem no primeiro
argumento (o `%i` do template).

Com `ALERTA_SNS_TOPICO` preenchido (em `/etc/softspend/alerta.env`, lido pelo
`EnvironmentFile` da unidade), publica no tópico SNS uma mensagem só com a
unidade, a máquina e a hora UTC — nunca trecho de log nem dado do banco. Sem
tópico configurado, não publica nada e sai 0 (alertas desligados).

Só usa a biblioteca padrão e o `boto3` (já na venv da API). Como o backup, o
envio usa só a função IAM da EC2: com chave AWS no ambiente o script recusa
rodar e sai 1.
"""

from __future__ import annotations

import argparse
import os
import socket
import sys
from datetime import datetime, timezone

# Com qualquer uma delas no ambiente, o boto3 a usaria no lugar da função IAM.
CHAVES_PROIBIDAS = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")


def montar_mensagem(unidade: str, host: str, agora: datetime) -> tuple[str, str]:
    """Assunto e corpo do aviso: só unidade, máquina, hora UTC e onde olhar."""
    hora = agora.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    assunto = f"SoftSpend: falhou {unidade}"
    corpo = (
        f"A unidade {unidade} falhou em {host} às {hora} (UTC).\n"
        f"Veja /var/log/softspend/ e rode: sudo journalctl -u {unidade} -n 100\n"
    )
    return assunto, corpo


def criar_cliente_sns(regiao: str | None):
    import boto3  # importado aqui para os testes não dependerem da AWS

    return boto3.client("sns", region_name=regiao or "sa-east-1")


def main(argv: list[str] | None = None,
         ambiente: dict[str, str] | None = None,
         cliente=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("unidade", help="unidade que falhou (%%i do template)")
    args = parser.parse_args(argv)

    ambiente = dict(os.environ) if ambiente is None else ambiente
    topico = (ambiente.get("ALERTA_SNS_TOPICO") or "").strip()
    if not topico:
        print("alerta sem tópico configurado")
        return 0

    chaves = [k for k in CHAVES_PROIBIDAS if ambiente.get(k)]
    if chaves:
        print(
            f"ERRO: {', '.join(chaves)} definida(s): o alerta usa só a função "
            "IAM da EC2, sem chave de acesso no ambiente",
            file=sys.stderr,
        )
        return 1

    if cliente is None:
        cliente = criar_cliente_sns(ambiente.get("AWS_REGION"))
    assunto, mensagem = montar_mensagem(
        args.unidade, socket.gethostname(), datetime.now(timezone.utc)
    )
    try:
        cliente.publish(TopicArn=topico, Subject=assunto, Message=mensagem)
    except Exception as e:
        print(f"ERRO: falha ao publicar no SNS: {e}", file=sys.stderr)
        return 1
    print(f"alerta publicado em {topico}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
