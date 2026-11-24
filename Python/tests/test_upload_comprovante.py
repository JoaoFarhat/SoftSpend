"""Tetos de tamanho do upload de imagem nas rotas de gasto.

`POST /gastos/{id}/comprovante` aceita imagem no mesmo teto do PDF (10 MB),
porque a nota que o app guarda chega a 9 MB (`NotaFiscal.tamanhoMaximo`).
`POST /gastos/extrair` — que alimenta o OCR — continua com o teto menor de
5 MB. O storage é falso: `salvar_comprovante` só registra o que subiria.
"""

from services import storage_service

from test_core_api import (
    USER_A,
    _criar_ciclo_dia_gasto,
    ambiente,  # fixture reutilizada de test_core_api
)


def _jpeg(tamanho: int) -> bytes:
    """JPEG pelos magic bytes: o `filetype` só olha os bytes iniciais."""
    return b"\xff\xd8\xff\xe0" + b"\x00" * (tamanho - 4)


def _post_comprovante(client, gasto_id: int, conteudo: bytes):
    return client.post(
        f"/gastos/{gasto_id}/comprovante",
        files={"imagem": ("nota.jpg", conteudo, "image/jpeg")},
    )


def _storage_falso(monkeypatch) -> dict:
    """Finge o S3 configurado e registra o que `salvar_comprovante` recebe."""
    enviados = {}

    def _salvar(user_id, gasto_id, conteudo, content_type):
        enviados["conteudo"] = conteudo
        enviados["tipo"] = content_type
        return f"comprovantes/{user_id}/{gasto_id}-fake.jpg"

    monkeypatch.setattr(storage_service, "esta_configurado", lambda: True)
    monkeypatch.setattr(storage_service, "salvar_comprovante", _salvar)
    return enviados


def test_jpeg_7mb_sobe_no_comprovante(ambiente, monkeypatch):
    enviados = _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(client, gasto["id"], _jpeg(7 * 1024 * 1024))

    assert resposta.status_code == 200
    assert len(enviados["conteudo"]) == 7 * 1024 * 1024
    assert enviados["tipo"] == "image/jpeg"


def test_jpeg_7mb_no_extrair_da_413(ambiente):
    client = ambiente.como(USER_A)

    resposta = client.post(
        "/gastos/extrair",
        files={"imagem": ("nota.jpg", _jpeg(7 * 1024 * 1024), "image/jpeg")},
    )

    assert resposta.status_code == 413


def test_imagem_11mb_no_comprovante_da_413(ambiente, monkeypatch):
    _storage_falso(monkeypatch)
    client = ambiente.como(USER_A)
    _, _, gasto = _criar_ciclo_dia_gasto(client)

    resposta = _post_comprovante(client, gasto["id"], _jpeg(11 * 1024 * 1024))

    assert resposta.status_code == 413
