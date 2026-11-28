"""Semáforo de decodificação do `services/storage_service.py`.

Uma foto de 48 Mpx (JPEG de até 9 MB, a resolução que o app manda) ocupa
~150 MB decodificada e passa de 400 MB com o giro EXIF e a redução. Na
t3.small (2 GB, que também roda o MySQL) poucos envios simultâneos — várias
contas mandando comprovantes ao voltar da viagem sem internet — faziam o
sistema matar o processo e derrubar a API.

`_conteudo_para_jpeg` e `_gerar_thumb` agora decodificam dentro de
`_semaforo_decodificacao` (padrão 2, `S3_MAX_DECODIFICACOES`). Os testes
trocam o semáforo por um `BoundedSemaphore(2)` próprio e espionam o
`exif_transpose` — o primeiro passo que decodifica os pixels — para segurar
as threads lá dentro e contar quantas decodificam ao mesmo tempo.
"""

import threading
from io import BytesIO

import pytest
from PIL import Image, ImageOps

from services import storage_service


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
