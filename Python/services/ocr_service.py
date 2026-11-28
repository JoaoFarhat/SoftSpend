import json
import logging
import os
import time
from io import BytesIO

import httpx
from google import genai
from google.genai import errors, types
from PIL import Image, ImageOps
from pydantic import BaseModel

from enums.categoria_enum import Categoria
from services import storage_service

logger = logging.getLogger(__name__)

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")

GEMINI_MODEL_NAME = os.getenv("GEMINI_MODEL_NAME", "gemini-3.5-flash-lite")

MAX_IMAGE_SIZE = int(os.getenv("OCR_MAX_IMAGE_SIZE", "1280"))

JPEG_QUALITY = int(os.getenv("OCR_JPEG_QUALITY", "80"))

MAX_OUTPUT_TOKENS = 256

_suporta_thinking_minimo = True

_client = (
    genai.Client(
        api_key=GEMINI_API_KEY,
        http_options=types.HttpOptions(
            timeout=12000,
            retry_options=types.HttpRetryOptions(attempts=2, initial_delay=0.5),
            client_args={
                "limits": httpx.Limits(
                    max_keepalive_connections=5,
                    max_connections=10,
                    keepalive_expiry=15.0,
                )
            },
        ),
    )
    if GEMINI_API_KEY
    else None
)


class SemRespostaGemini(ValueError):
    """O Gemini não respondeu (sem chave, rede, timeout ou 5xx): a cota é devolvida.

    Subclasse do `ValueError` que o endpoint já traduz hoje; `status_code` e
    `detail` guardam a resposta que cada caso já devolvia (422 para arquivo
    recusado/sem chave, 500 para a chamada que não teve resposta).
    """

    def __init__(self, detail: str, status_code: int = 422):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


class GastoExtraido(BaseModel):
    titulo: str
    valor: float
    categoria: Categoria


PROMPT = """Extraia dados de comprovantes/notas fiscais brasileiros.

titulo (max 40, Title Case): nome do estabelecimento. Apps de entrega: "iFood - Restaurante". Transporte: "Uber - Viagem".
valor: TOTAL pago apos descontos e taxas (rotulos TOTAL / VALOR PAGO / VLR PAGO). Nunca subtotal, troco ou item isolado. Ponto decimal (45.90).
categoria:
- ALIMENTACAO: restaurante, lanchonete, mercado, padaria, iFood, Rappi, acougue
- TRANSPORTE: Uber, 99, taxi, combustivel, posto, onibus, metro, estacionamento, pedagio, mecanica
- LAZER: cinema, show, parque, jogos, streaming, boate, bar
- COMPRAS: roupa, calcado, eletronico, livro, farmacia, perfumaria, movel, e-commerce
- OUTROS: contas, saude, educacao, demais casos

Imagem ilegivel ou nao-comprovante: titulo="Gasto", valor=0, categoria="OUTROS".
Responda apenas o JSON do schema.
"""


def _thinking_minimo() -> types.ThinkingConfig:
    if GEMINI_MODEL_NAME.startswith("gemini-2"):
        return types.ThinkingConfig(thinking_budget=0)
    return types.ThinkingConfig(thinking_level=types.ThinkingLevel.MINIMAL)


def _e_rejeicao_de_thinking(erro: Exception) -> bool:
    msg = str(erro).lower()
    return "thinking" in msg and (
        "invalid" in msg or "not supported" in msg or "unsupported" in msg
    )


def _montar_config(thinking_minimo: bool) -> types.GenerateContentConfig:
    return types.GenerateContentConfig(
        system_instruction=PROMPT,
        temperature=0.0,
        response_mime_type="application/json",
        response_schema=GastoExtraido,
        max_output_tokens=MAX_OUTPUT_TOKENS,
        thinking_config=_thinking_minimo() if thinking_minimo else None,
    )


def _sem_resposta(erro: Exception) -> bool:
    """A chamada ao Gemini não teve resposta: a vaga do dia volta.

    Só erro de conexão/timeout (`httpx.HTTPError`, o `send` da SDK) e 5xx
    (`ServerError`) não chegaram a resposta. O 4xx (`ClientError`, ex.:
    arquivo recusado) e qualquer outra falha gastam a cota — devolver a
    vaga numa recusa deixaria contornar o teto diário à vontade.
    """
    return isinstance(erro, (httpx.HTTPError, errors.ServerError))


def gerar_conteudo(
    client, model: str, part: types.Part, montar_config, fabricar_sem_resposta
):
    """Chama `generate_content` com o retry de 'thinking' e classifica a falha.

    Modelo que rejeita o thinking mínimo ("thinking ... invalid/not
    supported") desliga `_suporta_thinking_minimo` para as chamadas
    seguintes e refaz uma única vez sem a config.

    Erro de conexão, timeout ou 5xx: o Gemini não respondeu — lança
    `fabricar_sem_resposta()` (a exceção própria de cada serviço, que faz a
    vaga do dia voltar). 4xx e demais erros sobem crus: a chamada foi
    atendida e a cota ficou gasta.
    """
    global _suporta_thinking_minimo
    try:
        try:
            return client.models.generate_content(
                model=model,
                contents=[part],
                config=montar_config(thinking_minimo=_suporta_thinking_minimo),
            )
        except Exception as erro:
            if not (_suporta_thinking_minimo and _e_rejeicao_de_thinking(erro)):
                raise
            _suporta_thinking_minimo = False
            return client.models.generate_content(
                model=model,
                contents=[part],
                config=montar_config(thinking_minimo=False),
            )
    except Exception as erro:
        if not _sem_resposta(erro):
            raise
        logger.exception("Gemini sem resposta")
        raise fabricar_sem_resposta() from erro


def aquecer() -> None:
    if not _client:
        return

    inicio = time.perf_counter()
    try:
        _client.models.generate_content(
            model=GEMINI_MODEL_NAME,
            contents=[types.Part.from_text(text="ok")],
            config=types.GenerateContentConfig(max_output_tokens=1),
        )
        logger.info("Gemini aquecido em %.2fs", time.perf_counter() - inicio)
    except Exception as erro:
        logger.warning("Falha ao aquecer o Gemini (%.2fs): %s", time.perf_counter() - inicio, type(erro).__name__)


def _preprocessar_imagem(image_bytes: bytes) -> bytes:
    try:
        img = Image.open(BytesIO(image_bytes))
        # Image.open so le o cabecalho: o teto de pixels barra aqui a imagem
        # que explodiria a memoria ao decodificar.
        if img.width * img.height > storage_service.MAX_IMAGEM_PIXELS:
            raise SemRespostaGemini(
                "Imagem grande demais; tire outra foto ou anexe um PDF"
            )

        # O giro EXIF, a conversao e a reducao decodificam os pixels — na foto
        # de 48 Mpx sao centenas de MB. Ficam dentro do mesmo semaforo do
        # storage para o POST /gastos/extrair nao furar o teto de memoria.
        with storage_service._semaforo_decodificacao:
            img = ImageOps.exif_transpose(img)

            if img.mode != "RGB":
                img = img.convert("RGB")

            if max(img.size) > MAX_IMAGE_SIZE:
                img.thumbnail((MAX_IMAGE_SIZE, MAX_IMAGE_SIZE), Image.LANCZOS)

            buffer = BytesIO()
            img.save(buffer, format="JPEG", quality=JPEG_QUALITY, optimize=True)
        return buffer.getvalue()
    except SemRespostaGemini:
        raise
    except Exception as e:
        # A imagem nem chega ao Gemini: não gasta a cota do dia.
        logger.warning("Imagem invalida no OCR: %s", type(e).__name__)
        raise SemRespostaGemini("Não foi possível abrir esta imagem; tente outra foto")


def extrair_gasto_da_imagem(image_bytes: bytes) -> dict:
    if not _client:
        logger.error("GEMINI_API_KEY nao configurada")
        raise SemRespostaGemini("A leitura automática está indisponível agora; preencha o gasto à mão")

    inicio_preproc = time.perf_counter()
    imagem_otimizada = _preprocessar_imagem(image_bytes)
    duracao_preproc = time.perf_counter() - inicio_preproc
    imagem_part = types.Part.from_bytes(data=imagem_otimizada, mime_type="image/jpeg")

    inicio_gemini = time.perf_counter()
    response = gerar_conteudo(
        _client,
        GEMINI_MODEL_NAME,
        imagem_part,
        _montar_config,
        lambda: SemRespostaGemini("Erro ao processar imagem", status_code=500),
    )

    logger.info(
        "OCR %s: recebido %.0fKB -> enviado %.0fKB | preproc %.2fs | gemini %.2fs",
        GEMINI_MODEL_NAME,
        len(image_bytes) / 1024,
        len(imagem_otimizada) / 1024,
        duracao_preproc,
        time.perf_counter() - inicio_gemini,
    )

    dados = response.parsed
    if dados is None:
        if not response.text:
            raise ValueError("Não foi possível ler este comprovante; preencha o gasto à mão")
        try:
            dados = GastoExtraido(**json.loads(response.text))
        except Exception as e:
            logger.warning("Resposta inesperada do modelo no OCR: %s", type(e).__name__)
            raise ValueError("Não foi possível ler este comprovante; preencha o gasto à mão")

    return {
        "titulo": dados.titulo[:40],
        "valor": round(dados.valor, 2),
        "categoria": dados.categoria.value,
    }
