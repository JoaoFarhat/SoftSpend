"""Log do envio do e-mail de redefinicao (`services/email_service.py`).

`enviar_codigo_redefinicao` roda em background e nunca lanca: falha vira
`logger.error`. Quando o SES recusa (`ClientError`), o log precisa trazer o
`Error.Code` — `MessageRejected`, `AccessDeniedException`... — para saber se e
sandbox, dominio nao verificado ou falta de permissao. E nunca pode gravar o
e-mail do destinatario, o nome nem o codigo.
"""

import logging

from botocore.exceptions import ClientError

from services import email_service

REMETENTE = "SoftSpend <nao-responda@softspend.com.br>"


class _ClienteFalso:
    """Cliente SES v2 que conta as chamadas e falha com a excecao dada."""

    def __init__(self, exc):
        self.exc = exc
        self.chamadas = 0

    def send_email(self, **kwargs):
        self.chamadas += 1
        raise self.exc


def _enviar():
    email_service.enviar_codigo_redefinicao(
        "vitima@exemplo.com", "Vitima", "042917", 15
    )


def test_client_error_registra_o_codigo_do_ses(monkeypatch, caplog):
    """SES recusou: o log traz o Error.Code, sem o e-mail nem o codigo."""
    monkeypatch.setenv("EMAIL_REMETENTE", REMETENTE)
    falso = _ClienteFalso(
        ClientError(
            {
                "Error": {
                    "Code": "MessageRejected",
                    "Message": "Email address is not verified.",
                }
            },
            "SendEmail",
        )
    )
    monkeypatch.setattr(email_service, "_cliente", lambda: falso)

    with caplog.at_level(logging.ERROR, logger="services.email_service"):
        _enviar()

    assert falso.chamadas == 1
    assert "ClientError" in caplog.text
    assert "MessageRejected" in caplog.text
    assert "vitima@exemplo.com" not in caplog.text
    assert "Vitima" not in caplog.text
    assert "042917" not in caplog.text


def test_outra_excecao_registra_so_o_tipo(monkeypatch, caplog):
    """Erro fora do ClientError (rede, bug): o log fica so com o nome do tipo."""
    monkeypatch.setenv("EMAIL_REMETENTE", REMETENTE)
    falso = _ClienteFalso(RuntimeError("conexao caiu no meio do envio"))
    monkeypatch.setattr(email_service, "_cliente", lambda: falso)

    with caplog.at_level(logging.ERROR, logger="services.email_service"):
        _enviar()

    assert falso.chamadas == 1
    assert "RuntimeError" in caplog.text
    assert "conexao caiu" not in caplog.text
    assert "vitima@exemplo.com" not in caplog.text
    assert "Vitima" not in caplog.text
    assert "042917" not in caplog.text


def test_sem_remetente_avisa_e_nao_chama_o_cliente(monkeypatch, caplog):
    """Sem EMAIL_REMETENTE: aviso no log e o SES nao e nem criado."""
    monkeypatch.delenv("EMAIL_REMETENTE", raising=False)
    chamadas = []

    def _proibido():
        chamadas.append(1)
        return _ClienteFalso(None)

    monkeypatch.setattr(email_service, "_cliente", _proibido)

    with caplog.at_level(logging.WARNING, logger="services.email_service"):
        _enviar()

    assert chamadas == []
    assert "EMAIL_REMETENTE" in caplog.text
