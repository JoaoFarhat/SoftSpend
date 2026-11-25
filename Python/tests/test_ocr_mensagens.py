"""Mensagens do OCR que chegam ao app (`services/ocr_service.py`).

O 422 do `POST /gastos/extrair` devolve `detail=str(e)`: nada de erro do
Pillow, da configuração do servidor ou do conteúdo da nota pode vazar
para a tela. `_client` e `gerar_conteudo` são trocados por falsos —
nenhum teste chama o Gemini de verdade.
"""

import io
import logging
from types import SimpleNamespace

import pytest
from PIL import Image

from enums.categoria_enum import Categoria
from services import ocr_service

from test_core_api import (
    USER_A,
    ambiente,  # fixture reutilizada de test_core_api
)

MSG_IMAGEM = "Não foi possível abrir esta imagem; tente outra foto"
MSG_SEM_CHAVE = "A leitura automática está indisponível agora; preencha o gasto à mão"
MSG_LEITURA = "Não foi possível ler este comprovante; preencha o gasto à mão"


def _png_valido() -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (8, 8), "white").save(buffer, format="PNG")
    return buffer.getvalue()


def _resposta(parsed=None, text=""):
    return SimpleNamespace(parsed=parsed, text=text)


def _client_e_resposta(monkeypatch, resposta):
    monkeypatch.setattr(ocr_service, "_client", object())
    monkeypatch.setattr(
        ocr_service, "gerar_conteudo", lambda *args, **kwargs: resposta
    )


def test_bytes_que_nao_sao_imagem(monkeypatch):
    monkeypatch.setattr(ocr_service, "_client", object())

    with pytest.raises(ocr_service.SemRespostaGemini) as exc:
        ocr_service.extrair_gasto_da_imagem(b"isto nao e imagem")

    assert exc.value.status_code == 422
    assert exc.value.detail == MSG_IMAGEM
    assert "cannot identify" not in str(exc.value)


def test_sem_chave(monkeypatch):
    monkeypatch.setattr(ocr_service, "_client", None)

    with pytest.raises(ocr_service.SemRespostaGemini) as exc:
        ocr_service.extrair_gasto_da_imagem(_png_valido())

    assert exc.value.status_code == 422
    assert exc.value.detail == MSG_SEM_CHAVE
    assert "GEMINI_API_KEY" not in str(exc.value)


def test_resposta_sem_parse_com_texto_da_nota(monkeypatch):
    _client_e_resposta(
        monkeypatch,
        _resposta(
            parsed=None,
            text='{"titulo": "Padaria Central", "valor": "x"}',
        ),
    )

    with pytest.raises(ValueError) as exc:
        ocr_service.extrair_gasto_da_imagem(_png_valido())

    assert str(exc.value) == MSG_LEITURA
    assert "Padaria" not in str(exc.value)
    assert "validation error" not in str(exc.value)


def test_resposta_sem_parse_sem_texto(monkeypatch):
    _client_e_resposta(monkeypatch, _resposta(parsed=None, text=""))

    with pytest.raises(ValueError) as exc:
        ocr_service.extrair_gasto_da_imagem(_png_valido())

    assert str(exc.value) == MSG_LEITURA


def test_resposta_valida(monkeypatch):
    _client_e_resposta(
        monkeypatch,
        _resposta(
            parsed=ocr_service.GastoExtraido(
                titulo="Padaria Central",
                valor=45.9,
                categoria=Categoria.ALIMENTACAO,
            )
        ),
    )

    assert ocr_service.extrair_gasto_da_imagem(_png_valido()) == {
        "titulo": "Padaria Central",
        "valor": 45.9,
        "categoria": "ALIMENTACAO",
    }


def test_erro_inesperado_do_ocr_vai_para_o_log(ambiente, monkeypatch, caplog):
    """Bug no meio da leitura: o app vê o 500 amigável e a causa fica no log.

    Sem o `logger.exception` do `except Exception`, o `app.log` só mostraria
    "status 500" e ninguém saberia o que quebrou.
    """

    def _quebrado(conteudo):
        raise RuntimeError("boom")

    monkeypatch.setattr(ocr_service, "extrair_gasto_da_imagem", _quebrado)
    client = ambiente.como(USER_A)

    with caplog.at_level(logging.ERROR, logger="controllers.gasto_controller"):
        resposta = client.post(
            "/gastos/extrair",
            files={"imagem": ("nota.png", _png_valido(), "image/png")},
        )

    assert resposta.status_code == 500
    assert resposta.json()["error"] == "Erro ao processar imagem"
    assert "boom" not in resposta.text

    registro = next(
        r for r in caplog.records if r.name == "controllers.gasto_controller"
    )
    assert registro.levelno == logging.ERROR
    assert registro.exc_info is not None
    assert registro.exc_info[0] is RuntimeError
