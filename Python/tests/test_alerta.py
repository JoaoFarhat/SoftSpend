"""Testes do aviso por e-mail de unidades que falham (deploy/ec2/alertar.py)."""

import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

_CAMINHO = Path(__file__).resolve().parents[2] / "deploy" / "ec2" / "alertar.py"
_spec = importlib.util.spec_from_file_location("alertar", _CAMINHO)
alertar = importlib.util.module_from_spec(_spec)
sys.modules["alertar"] = alertar
_spec.loader.exec_module(alertar)

_UNIDADE = "softspend-backup.service"
_TOPICO = "arn:aws:sns:sa-east-1:123456789012:softspend-alertas"
AGORA = datetime(2026, 11, 25, 13, 30, 45, tzinfo=timezone.utc)


class SNSFalso:
    def __init__(self, erro=None):
        self.chamadas = []
        self.erro = erro

    def publish(self, **kwargs):
        self.chamadas.append(kwargs)
        if self.erro is not None:
            raise self.erro


# --- mensagem ----------------------------------------------------------------


def test_mensagem_so_traz_unidade_host_hora_e_onde_olhar():
    assunto, corpo = alertar.montar_mensagem(_UNIDADE, "ip-10-0-0-7", AGORA)
    assert assunto == f"SoftSpend: falhou {_UNIDADE}"
    assert corpo == (
        f"A unidade {_UNIDADE} falhou em ip-10-0-0-7 às "
        "2026-11-25T13:30:45Z (UTC).\n"
        f"Veja /var/log/softspend/ e rode: sudo journalctl -u {_UNIDADE} -n 100\n"
    )


# --- main --------------------------------------------------------------------


@pytest.mark.parametrize("vazio", [None, "", "   "])
def test_sem_topico_nao_publica_e_sai_0(vazio, capsys):
    sns = SNSFalso()
    ambiente = {} if vazio is None else {"ALERTA_SNS_TOPICO": vazio}
    assert alertar.main([_UNIDADE], ambiente, cliente=sns) == 0
    assert sns.chamadas == []
    assert "alerta sem tópico configurado" in capsys.readouterr().out


def test_com_topico_publica_uma_vez_com_arn_e_unidade_no_assunto():
    sns = SNSFalso()
    assert alertar.main([_UNIDADE], {"ALERTA_SNS_TOPICO": _TOPICO}, cliente=sns) == 0
    assert len(sns.chamadas) == 1
    chamada = sns.chamadas[0]
    assert chamada["TopicArn"] == _TOPICO
    assert chamada["Subject"] == f"SoftSpend: falhou {_UNIDADE}"
    assert _UNIDADE in chamada["Message"]


def test_erro_do_cliente_sai_1(capsys):
    sns = SNSFalso(erro=RuntimeError("sns fora do ar"))
    assert alertar.main([_UNIDADE], {"ALERTA_SNS_TOPICO": _TOPICO}, cliente=sns) == 1
    assert "falha ao publicar" in capsys.readouterr().err


@pytest.mark.parametrize("chave", ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
def test_chave_aws_no_ambiente_sai_1_sem_publicar(chave, capsys):
    sns = SNSFalso()
    ambiente = {"ALERTA_SNS_TOPICO": _TOPICO, chave: "AKIA123"}
    assert alertar.main([_UNIDADE], ambiente, cliente=sns) == 1
    assert sns.chamadas == []
    assert "função IAM" in capsys.readouterr().err


# --- unidades do systemd ------------------------------------------------------


@pytest.mark.parametrize(
    "servico", ["softspend-backup.service", "softspend-assinaturas.service"]
)
def test_unidade_tem_onfailure_do_alerta(servico):
    texto = (_CAMINHO.parent / servico).read_text(encoding="utf-8")
    secao_unit = texto.split("[Service]")[0]
    assert "OnFailure=softspend-alerta@%n.service" in secao_unit.splitlines()


def test_template_chama_alertar_com_a_instancia():
    texto = (_CAMINHO.parent / "softspend-alerta@.service").read_text(
        encoding="utf-8"
    )
    assert "Type=oneshot" in texto
    assert "EnvironmentFile=-/etc/softspend/alerta.env" in texto
    assert "alertar.py %i" in texto
