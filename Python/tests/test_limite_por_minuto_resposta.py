"""Resposta do 429 do limite por minuto (slowapi).

O handler próprio (`middlewares.rate_limit_exceeded_handler`, registrado em
`main` no lugar do padrão do slowapi) responde em português e com
`request_id`, como os outros erros da API, e mantém os cabeçalhos de limite
do `_inject_headers`. O 429 `daily_ai_limit` (teto diário de IA por usuário,
`services/limite_ia.py`) é HTTPException, não passa pelo slowapi e segue com
o mesmo corpo de antes.
"""

import pytest
from fastapi.testclient import TestClient

import limiter as limiter_module
from middlewares import MENSAGEM_LIMITE_POR_MINUTO
from services import limite_ia
from test_hardening import _uma_copia_do_limite_de_health

# PNG mínimo: o `_ler_arquivo` só olha os bytes iniciais.
_PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + b"\x00" * 32


@pytest.fixture
def app_health_limitado(monkeypatch):
    """App com cada request ao /health custando 1 hit, como em produção."""
    from main import app

    _uma_copia_do_limite_de_health(monkeypatch)
    limiter_module.limiter.reset()
    try:
        yield app
    finally:
        limiter_module.limiter.reset()


def test_429_do_limite_por_minuto_sai_em_portugues_com_request_id(
    app_health_limitado,
):
    client = TestClient(app_health_limitado)
    resposta = None
    for _ in range(31):
        resposta = client.get("/health")

    assert resposta.status_code == 429
    corpo = resposta.json()
    assert corpo["error"] == MENSAGEM_LIMITE_POR_MINUTO
    assert corpo["request_id"]
    assert corpo["request_id"] == resposta.headers["x-request-id"]


def test_429_do_limite_por_minuto_mantem_cabecalhos_de_limite(
    app_health_limitado, monkeypatch
):
    """O handler continua chamando `_inject_headers`: com `headers_enabled`
    ligado, os cabeçalhos X-RateLimit/Retry-After saem como antes."""
    monkeypatch.setattr(limiter_module.limiter, "_headers_enabled", True)

    client = TestClient(app_health_limitado)
    resposta = None
    for _ in range(31):
        resposta = client.get("/health")

    assert resposta.status_code == 429
    assert resposta.headers["X-RateLimit-Limit"] == "30"
    assert "X-RateLimit-Remaining" in resposta.headers
    assert "X-RateLimit-Reset" in resposta.headers
    assert "Retry-After" in resposta.headers


def test_429_daily_ai_limit_segue_igual(monkeypatch):
    """O teto diário de IA não é slowapi: o corpo continua `daily_ai_limit`."""
    from dependencies import get_current_user_id
    from main import app

    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "1")
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    app.dependency_overrides[get_current_user_id] = lambda: "user-429"
    limite_ia._contadores.clear()
    try:
        # A vaga do dia já foi gasta: o pedido leva 429 antes de chegar à IA.
        limite_ia.contar("user-429", limite_ia.COMPROVANTE)
        resposta = TestClient(app).post(
            "/gastos/extrair",
            files={"imagem": ("nota.png", _PNG, "image/png")},
        )
    finally:
        limite_ia._contadores.clear()
        app.dependency_overrides.clear()

    assert resposta.status_code == 429
    assert resposta.json()["error"] == "daily_ai_limit"
