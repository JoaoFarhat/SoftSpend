"""A trava do pypdfium2 (`services/pdfium_seguro.trava_pdfium`).

O pypdfium2 não é seguro entre threads e o FastAPI chama
`desproteger_pdf` (fatura) e `pdf_primeira_pagina_para_jpeg`
(comprovante) no threadpool: sem a trava, dois PDFs ao mesmo tempo
podiam derrubar o processo único do uvicorn. Os testes trocam o módulo
`pypdfium2` por um falso que anota se a trava estava presa a cada chamada
e conta quantas threads estão dentro do "pdfium" ao mesmo tempo.
"""

import sys
import threading
import time

import pytest

from services import fatura_arquivo_service, pdfium_seguro, storage_service


class PdfiumFalso:
    """Finge o módulo pypdfium2 registrando trava e concorrência."""

    def __init__(self, protegido: bool = False, lentidao: float = 0.0):
        self.PdfiumError = type("PdfiumError", (Exception,), {})
        self.protegido = protegido
        self.lentidao = lentidao
        self.trava_presa: list[bool] = []
        self._dentro = 0
        self.maximo_dentro = 0
        falso = self

        class _Pagina:
            def get_size(self):
                falso._anotar()
                return (612.0, 792.0)

            def render(self, scale):
                falso._anotar()
                return _Bitmap()

        class _Bitmap:
            def to_pil(self):
                falso._anotar()
                from PIL import Image

                return Image.new("RGB", (8, 8))

        class PdfDocument:
            def __init__(self, conteudo, password=None):
                falso._anotar()
                if falso.protegido and password is None:
                    raise falso.PdfiumError("incorrect password")

            @classmethod
            def new(cls):
                falso._anotar()
                return cls.__new__(cls)

            def __len__(self):
                falso._anotar()
                return 1

            def __getitem__(self, indice):
                falso._anotar()
                return _Pagina()

            def import_pages(self, outro):
                falso._anotar()

            def save(self, buffer):
                falso._anotar()
                buffer.write(b"%PDF-falso")

            def close(self):
                falso._anotar()

        self.PdfDocument = PdfDocument

    def _anotar(self):
        self.trava_presa.append(pdfium_seguro.trava_pdfium.locked())
        self._dentro += 1
        self.maximo_dentro = max(self.maximo_dentro, self._dentro)
        if self.lentidao:
            time.sleep(self.lentidao)
        self._dentro -= 1


@pytest.fixture
def pdfium_falso(monkeypatch):
    """Instala o pypdfium2 falso como `sys.modules["pypdfium2"]`.

    Os serviços importam `pypdfium2` dentro da função, então trocar o
    módulo já carregado basta — o `import` na hora do uso pega o falso.
    """

    def _instalar(**kwargs) -> PdfiumFalso:
        falso = PdfiumFalso(**kwargs)
        monkeypatch.setitem(sys.modules, "pypdfium2", falso)
        return falso

    return _instalar


def test_desproteger_pdf_so_chama_pdfium_com_a_trava_presa(pdfium_falso):
    falso = pdfium_falso()

    resultado = fatura_arquivo_service.desproteger_pdf(b"%PDF-1.4 fake", None)

    assert resultado == b"%PDF-1.4 fake"
    assert falso.trava_presa  # o pdfium foi chamado
    assert all(falso.trava_presa)


def test_desproteger_pdf_com_senha_so_chama_pdfium_com_a_trava_presa(
    pdfium_falso,
):
    falso = pdfium_falso(protegido=True)

    resultado = fatura_arquivo_service.desproteger_pdf(b"%PDF-1.4 fake", "1234")

    assert resultado == b"%PDF-falso"
    assert falso.trava_presa
    assert all(falso.trava_presa)


def test_raster_do_comprovante_so_chama_pdfium_com_a_trava_presa(pdfium_falso):
    falso = pdfium_falso()

    jpeg = storage_service.pdf_primeira_pagina_para_jpeg(b"%PDF-1.4 fake")

    assert jpeg[:2] == b"\xff\xd8"  # JPEG
    assert falso.trava_presa
    assert all(falso.trava_presa)


def test_duas_threads_nunca_entram_juntas_no_pdfium(pdfium_falso):
    """Duas chamadas simultâneas a `desproteger_pdf` ficam serializadas:
    o máximo de threads dentro do pdfium ao mesmo tempo é 1."""
    falso = pdfium_falso(lentidao=0.02)
    erros = []

    def trabalhar():
        try:
            for _ in range(5):
                fatura_arquivo_service.desproteger_pdf(b"%PDF-1.4 fake", None)
        except Exception as exc:  # noqa: BLE001 - repassa qualquer falha
            erros.append(exc)

    threads = [threading.Thread(target=trabalhar) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not erros
    assert falso.maximo_dentro == 1
    assert all(falso.trava_presa)
