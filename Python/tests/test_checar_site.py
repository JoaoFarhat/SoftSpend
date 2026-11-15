"""Testes do monitor do site (deploy/monitor/checar_site.py), sem rede."""

import importlib.util
import socket
import urllib.error
from datetime import datetime, timedelta, timezone
from pathlib import Path

_CAMINHO = Path(__file__).resolve().parents[2] / "deploy" / "monitor" / "checar_site.py"
_spec = importlib.util.spec_from_file_location("checar_site", _CAMINHO)
cs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cs)

AGORA = datetime(2026, 11, 15, 12, 0, 0, tzinfo=timezone.utc)


def _not_after(dias: int) -> str:
    vencimento = AGORA + timedelta(days=dias)
    return vencimento.strftime("%b %d %H:%M:%S %Y GMT")


# ---------------------------------------------------------------------------
# avaliar_health
# ---------------------------------------------------------------------------


def test_health_200_ok():
    assert cs.avaliar_health(200, b'{"status": "ok"}') is None


def test_health_503_falha():
    assert cs.avaliar_health(503, b"Service Unavailable") == "HTTP 503"


def test_health_200_outro_corpo_falha():
    assert cs.avaliar_health(200, b'{"status": "degraded"}') is not None
    assert cs.avaliar_health(200, b"ok") is not None


def test_dias_ate_vencer():
    assert cs.dias_ate_vencer("Jan 17 12:00:00 2027 GMT", AGORA) == 63


# ---------------------------------------------------------------------------
# checar_health (rede falsa)
# ---------------------------------------------------------------------------


def test_checar_health_passa():
    def buscar(host, timeout):
        return 200, b'{"status": "ok"}'

    assert cs.checar_health("exemplo.com", buscar=buscar, dormir=lambda s: None) is None


def test_checar_health_erro_de_rede_falha_com_motivo():
    def buscar(host, timeout):
        raise urllib.error.URLError("sem DNS")

    motivo = cs.checar_health("exemplo.com", buscar=buscar, dormir=lambda s: None)
    assert motivo is not None
    assert "sem DNS" in motivo


def test_checar_health_timeout_falha_com_motivo():
    def buscar(host, timeout):
        raise socket.timeout("timed out")

    motivo = cs.checar_health("exemplo.com", buscar=buscar, dormir=lambda s: None)
    assert motivo is not None
    assert "timed out" in motivo


def test_checar_health_retenta_e_nao_alarma_soluco():
    chamadas = []
    dormidas = []

    def buscar(host, timeout):
        chamadas.append(host)
        if len(chamadas) == 1:
            raise socket.timeout("timed out")
        return 200, b'{"status": "ok"}'

    assert (
        cs.checar_health("exemplo.com", buscar=buscar, dormir=dormidas.append)
        is None
    )
    assert len(chamadas) == 2
    assert dormidas == [cs.ESPERA_ENTRE_TENTATIVAS_S]


def test_checar_health_503_nas_duas_falha():
    def buscar(host, timeout):
        return 503, b"indisponivel"

    motivo = cs.checar_health("exemplo.com", buscar=buscar, dormir=lambda s: None)
    assert motivo == "HTTP 503"


# ---------------------------------------------------------------------------
# checar_certificado (rede falsa)
# ---------------------------------------------------------------------------


def test_certificado_30_dias_passa():
    motivo = cs.checar_certificado(
        "exemplo.com", agora=AGORA, ler_not_after=lambda h: _not_after(30)
    )
    assert motivo is None


def test_certificado_10_dias_falha():
    motivo = cs.checar_certificado(
        "exemplo.com", agora=AGORA, ler_not_after=lambda h: _not_after(10)
    )
    assert motivo is not None
    assert "10 dias" in motivo


def test_certificado_erro_de_rede_falha_com_motivo():
    def ler(host):
        raise OSError("conexão recusada")

    motivo = cs.checar_certificado("exemplo.com", agora=AGORA, ler_not_after=ler)
    assert motivo is not None
    assert "conexão recusada" in motivo


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def test_main_sai_0_quando_tudo_certo(capsys):
    saida = cs.main(
        ["exemplo.com"],
        checar_h=lambda h: None,
        checar_c=lambda h: None,
    )
    assert saida == 0
    assert capsys.readouterr().out.count("ok") == 2


def test_main_sai_1_quando_algo_falha(capsys):
    saida = cs.main(
        ["exemplo.com"],
        checar_h=lambda h: "HTTP 503",
        checar_c=lambda h: None,
    )
    assert saida == 1
    assert "FALHOU" in capsys.readouterr().out


def test_main_host_padrao():
    hosts = []
    saida = cs.main(
        [],
        checar_h=lambda h: hosts.append(h) or None,
        checar_c=lambda h: hosts.append(h) or None,
    )
    assert saida == 0
    assert hosts == [cs.HOST_PADRAO, cs.HOST_PADRAO]


# ---------------------------------------------------------------------------
# workflow
# ---------------------------------------------------------------------------


def test_workflow_tem_cron_e_dispatch():
    texto = (
        Path(__file__).resolve().parents[2] / ".github" / "workflows" / "monitor.yml"
    ).read_text(encoding="utf-8")
    assert 'cron: "*/30 * * * *"' in texto
    assert "workflow_dispatch" in texto
