"""Semáforo de decodificação do `services/storage_service.py`.

Uma foto de 48 Mpx (JPEG de até 9 MB, a resolução que o app manda) ocupa
~150 MB decodificada e passa de 400 MB com o giro EXIF e a redução. Na
t3.small (2 GB, que também roda o MySQL) poucos envios simultâneos — várias
contas mandando comprovantes ao voltar da viagem sem internet — faziam o
sistema matar o processo e derrubar a API.

`_conteudo_para_jpeg`, `_gerar_thumb` e o `_preprocessar_imagem` do
`ocr_service` (a foto do `POST /gastos/extrair`) decodificam dentro de
`_semaforo_decodificacao`. O número de vagas vem de `_int_do_env`
(`S3_MAX_DECODIFICACOES`, padrão 2, piso 1): um `0` criaria o semáforo sem
vaga e um texto inválido quebraria o import. Os testes trocam o semáforo
por um `BoundedSemaphore` próprio e espionam o `exif_transpose` — o
primeiro passo que decodifica os pixels — para segurar as threads lá dentro
e contar quantas decodificam ao mesmo tempo.
"""

import logging
import threading
from io import BytesIO

import pytest
from PIL import Image, ImageOps

from services import ocr_service, storage_service


def _jpeg() -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (64, 64), (180, 90, 40)).save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture
def semaforo(monkeypatch):
    """Semáforo de 2 vagas próprio do teste, no lugar do criado pelo módulo."""
    semaforo = threading.BoundedSemaphore(2)
    monkeypatch.setattr(storage_service, "_semaforo_decodificacao", semaforo)
    return semaforo


class _EspiaoExif:
    """Segura a thread dentro da decodificação e conta quantas estão lá."""

    def __init__(self, monkeypatch):
        self.dentro = 0
        self.maximo_dentro = 0
        self.duas_dentro = threading.Event()
        self.portao = threading.Event()
        self._lock = threading.Lock()
        exif_original = ImageOps.exif_transpose

        def espiando(img):
            with self._lock:
                self.dentro += 1
                self.maximo_dentro = max(self.maximo_dentro, self.dentro)
                if self.dentro == 2:
                    self.duas_dentro.set()
            self.portao.wait(timeout=10)
            try:
                return exif_original(img)
            finally:
                with self._lock:
                    self.dentro -= 1

        monkeypatch.setattr(ImageOps, "exif_transpose", espiando)


def _decodificar_em_thread(conteudo: bytes, resultados: list, erros: list):
    def trabalhar():
        try:
            resultados.append(storage_service._conteudo_para_jpeg(conteudo))
        except Exception as exc:  # noqa: BLE001 - repassa qualquer falha
            erros.append(exc)

    thread = threading.Thread(target=trabalhar, daemon=True)
    thread.start()
    return thread


def test_terceira_decodificacao_espera_vaga(semaforo, monkeypatch):
    """Com as 2 vagas ocupadas por threads decodificando, a 3ª espera."""
    espiao = _EspiaoExif(monkeypatch)
    resultados, erros = [], []

    t1 = _decodificar_em_thread(_jpeg(), resultados, erros)
    t2 = _decodificar_em_thread(_jpeg(), resultados, erros)

    assert espiao.duas_dentro.wait(timeout=5)  # as duas vagas estão ocupadas

    t3 = _decodificar_em_thread(_jpeg(), resultados, erros)
    t3.join(timeout=0.5)

    assert t3.is_alive()  # a terceira thread espera a vaga
    assert espiao.dentro == 2  # e não entrou na decodificação

    espiao.portao.set()
    for t in (t1, t2, t3):
        t.join(timeout=10)

    assert not erros
    assert len(resultados) == 3
    assert espiao.maximo_dentro == 2
    assert all(jpeg[:2] == b"\xff\xd8" for jpeg, _ in resultados)


def test_vaga_devolvida_quando_a_imagem_e_recusada(semaforo, monkeypatch):
    """A decodificação que explode vira `ValueError` e a vaga é devolvida."""
    def quebrar(img):
        raise OSError("decoder quebrou")

    monkeypatch.setattr(ImageOps, "exif_transpose", quebrar)

    with pytest.raises(ValueError, match="Não foi possível abrir esta imagem"):
        storage_service._conteudo_para_jpeg(_jpeg())

    # O `with` devolveu a vaga no erro: as duas vagas continuam livres.
    assert semaforo.acquire(blocking=False)
    assert semaforo.acquire(blocking=False)


def test_gerar_thumb_tambem_espera_vaga(semaforo):
    """`_gerar_thumb` decodifica dentro do mesmo semáforo."""
    semaforo.acquire()
    semaforo.acquire()

    resultados = []
    thread = threading.Thread(
        target=lambda: resultados.append(storage_service._gerar_thumb(_jpeg())),
        daemon=True,
    )
    thread.start()
    thread.join(timeout=0.5)

    assert thread.is_alive()  # sem vaga, a miniatura espera

    semaforo.release()
    thread.join(timeout=10)
    semaforo.release()

    assert not thread.is_alive()
    assert resultados[0][:2] == b"\xff\xd8"  # JPEG


def test_max_decodificacoes_zero_vira_uma_vaga(monkeypatch):
    """`S3_MAX_DECODIFICACOES=0` criaria o semáforo sem vaga — o piso é 1."""
    monkeypatch.setenv("S3_MAX_DECODIFICACOES", "0")
    assert storage_service._int_do_env("S3_MAX_DECODIFICACOES", 2) == 1


def test_max_decodificacoes_invalido_cai_no_padrao(monkeypatch, caplog):
    """Texto inválido cai no padrão 2 e o aviso só nomeia a variável."""
    monkeypatch.setenv("S3_MAX_DECODIFICACOES", "abc")
    with caplog.at_level(logging.WARNING, logger="services.storage_service"):
        assert storage_service._int_do_env("S3_MAX_DECODIFICACOES", 2) == 2
    assert "S3_MAX_DECODIFICACOES" in caplog.text
    assert "abc" not in caplog.text


def test_max_decodificacoes_valido(monkeypatch):
    monkeypatch.setenv("S3_MAX_DECODIFICACOES", "3")
    assert storage_service._int_do_env("S3_MAX_DECODIFICACOES", 2) == 3


def test_ocr_preprocessa_dentro_do_semaforo(monkeypatch):
    """Com a vaga ocupada, `_preprocessar_imagem` espera; liberada, termina."""
    semaforo = threading.BoundedSemaphore(1)
    semaforo.acquire()
    monkeypatch.setattr(storage_service, "_semaforo_decodificacao", semaforo)

    resultados, erros = [], []

    def trabalhar():
        try:
            resultados.append(ocr_service._preprocessar_imagem(_jpeg()))
        except Exception as exc:  # noqa: BLE001 - repassa qualquer falha
            erros.append(exc)

    thread = threading.Thread(target=trabalhar, daemon=True)
    thread.start()
    thread.join(timeout=0.5)

    assert thread.is_alive()  # sem vaga, o preprocessamento espera

    semaforo.release()
    thread.join(timeout=10)

    assert not thread.is_alive()
    assert not erros
    assert resultados[0][:2] == b"\xff\xd8"  # JPEG


def test_ocr_devolve_vaga_quando_a_decodificacao_falha(monkeypatch):
    """Imagem que abre mas explode na decodificação devolve a vaga."""
    semaforo = threading.BoundedSemaphore(1)
    monkeypatch.setattr(storage_service, "_semaforo_decodificacao", semaforo)

    def quebrar(img):
        raise OSError("decoder quebrou")

    monkeypatch.setattr(ImageOps, "exif_transpose", quebrar)

    with pytest.raises(ocr_service.SemRespostaGemini, match="Não foi possível abrir esta imagem"):
        ocr_service._preprocessar_imagem(_jpeg())

    # O `with` devolveu a vaga no erro: ela continua livre.
    assert semaforo.acquire(blocking=False)


def test_ocr_teto_de_pixels_nao_espera_vaga(monkeypatch):
    """O teto de pixels barra a imagem antes de pegar a vaga do semáforo."""
    semaforo = threading.BoundedSemaphore(1)
    semaforo.acquire()
    monkeypatch.setattr(storage_service, "_semaforo_decodificacao", semaforo)
    monkeypatch.setattr(storage_service, "MAX_IMAGEM_PIXELS", 10)

    # Se o teto ficasse dentro do semáforo isto travaria esperando a vaga.
    with pytest.raises(ocr_service.SemRespostaGemini, match="Imagem grande demais"):
        ocr_service._preprocessar_imagem(_jpeg())
