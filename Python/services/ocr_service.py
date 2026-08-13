import json
import logging
import os
import time
from io import BytesIO

import httpx
from google import genai
from google.genai import types
from PIL import Image, ImageOps
from pydantic import BaseModel

from enums.categoria_enum import Categoria

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
        img = ImageOps.exif_transpose(img)

        if img.mode != "RGB":
            img = img.convert("RGB")

        if max(img.size) > MAX_IMAGE_SIZE:
            img.thumbnail((MAX_IMAGE_SIZE, MAX_IMAGE_SIZE), Image.LANCZOS)

        buffer = BytesIO()
        img.save(buffer, format="JPEG", quality=JPEG_QUALITY, optimize=True)
        return buffer.getvalue()
    except Exception as e:
        raise ValueError(f"Imagem invalida: {e}")


def extrair_gasto_da_imagem(image_bytes: bytes) -> dict:
    if not _client:
        raise ValueError("GEMINI_API_KEY nao configurada no ambiente")

    inicio_preproc = time.perf_counter()
    imagem_otimizada = _preprocessar_imagem(image_bytes)
    duracao_preproc = time.perf_counter() - inicio_preproc
    imagem_part = types.Part.from_bytes(data=imagem_otimizada, mime_type="image/jpeg")

    inicio_gemini = time.perf_counter()
    global _suporta_thinking_minimo
    try:
        response = _client.models.generate_content(
            model=GEMINI_MODEL_NAME,
            contents=[imagem_part],
            config=_montar_config(thinking_minimo=_suporta_thinking_minimo),
        )
    except Exception as erro:
        if not (_suporta_thinking_minimo and _e_rejeicao_de_thinking(erro)):
            raise
        _suporta_thinking_minimo = False
        response = _client.models.generate_content(
            model=GEMINI_MODEL_NAME,
            contents=[imagem_part],
            config=_montar_config(thinking_minimo=False),
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
            raise ValueError("Modelo nao retornou dados estruturados")
        try:
            dados = GastoExtraido(**json.loads(response.text))
        except (json.JSONDecodeError, Exception) as e:
            raise ValueError(f"Modelo retornou resposta inesperada: {response.text[:200]} ({e})")

    return {
        "titulo": dados.titulo[:40],
        "valor": round(dados.valor, 2),
        "categoria": dados.categoria.value,
    }
