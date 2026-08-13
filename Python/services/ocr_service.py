"""
ocr_service.py
==============

Servico de extracao automatica de dados a partir de comprovantes/notas fiscais
brasileiras usando o modelo Gemini 2.5 Flash da Google (multimodal).

"""

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

# Limite maximo de dimensao da imagem (maior lado). Imagens maiores sao redimensionadas.
# 1280px e o menor tamanho que ainda mantem texto de cupom legivel; abaixo disso
MAX_IMAGE_SIZE = int(os.getenv("OCR_MAX_IMAGE_SIZE", "1280"))

# Qualidade JPEG no recompactamento (80 mantem texto legivel com payload menor).
JPEG_QUALITY = int(os.getenv("OCR_JPEG_QUALITY", "80"))

MAX_OUTPUT_TOKENS = 256

_suporta_thinking_minimo = True

_client = (
    genai.Client(
        api_key=GEMINI_API_KEY,
        http_options=types.HttpOptions(
            timeout=12000,  # 12 segundos por tentativa
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
    """
    Schema de saida estruturada exigido do Gemini.
    
    O Gemini garante que a resposta seguira EXATAMENTE este formato quando
    passado em `response_schema`, elimina a necessidade de parsing manual
    de JSON ou regex sobre texto livre.
    
    Campos:
        titulo: Descricao curta do gasto (max 40 chars apos truncamento).
        valor: Valor TOTAL pago em reais (float, 2 casas decimais).
        categoria: Enum da categoria do gasto (validado pelo Pydantic).
    """
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
    """
    Config de raciocinio minimo para o modelo atual.

    Reduzir o thinking e a maior economia de latencia: em extracao guiada por
    `response_schema` o raciocinio interno nao agrega qualidade. A familia 2.x
    aceita `thinking_budget=0`; a 3.x usa `thinking_level`, onde MINIMAL e o
    menor nivel disponivel.
    """
    if GEMINI_MODEL_NAME.startswith("gemini-2"):
        return types.ThinkingConfig(thinking_budget=0)
    return types.ThinkingConfig(thinking_level=types.ThinkingLevel.MINIMAL)


def _e_rejeicao_de_thinking(erro: Exception) -> bool:
    """
    Indica se o erro e uma rejeicao da config de thinking pelo modelo.

    Precisa ser especifico: erros de rede (timeout, 5xx) NAO devem cair no
    fallback, senao uma instabilidade transitoria dispara uma segunda
    requisicao completa e desativa o thinking minimo para todo o processo.
    """
    msg = str(erro).lower()
    return "thinking" in msg and (
        "invalid" in msg or "not supported" in msg or "unsupported" in msg
    )


def _montar_config(thinking_minimo: bool) -> types.GenerateContentConfig:
    """
    Monta a config de geracao.

    Args:
        thinking_minimo: Se True, aplica `_thinking_minimo()`. Modelos que
            rejeitarem essa config caem no retry sem `thinking_config`.
    """
    return types.GenerateContentConfig(
        system_instruction=PROMPT,
        temperature=0.0,
        response_mime_type="application/json",
        response_schema=GastoExtraido,
        max_output_tokens=MAX_OUTPUT_TOKENS,
        thinking_config=_thinking_minimo() if thinking_minimo else None,
    )


def aquecer() -> None:
    """
    Faz uma requisicao minima ao Gemini para pagar o custo de cold start.

    A primeira chamada de um processo novo leva ~15-26s (handshake TLS, init do
    SDK e warm-up do modelo), enquanto as seguintes levam ~1.2s. Sem aquecer, e
    o primeiro escaneamento do usuario que paga essa conta.

    Falhas sao apenas logadas: aquecer e uma otimizacao, nunca deve impedir o
    servidor de subir.
    """
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
        logger.warning("Falha ao aquecer o Gemini (%.2fs): %s", time.perf_counter() - inicio, erro)


def _preprocessar_imagem(image_bytes: bytes) -> bytes:
    """
    Normaliza e otimiza a imagem antes de enviar ao Gemini.
    
    Etapas:
        1. Aplica `exif_transpose`: corrige rotacao baseada nos metadados EXIF.
           Isso e essencial para fotos do iPhone que vem deitadas porem com flag
           de rotacao no EXIF.
        2. Converte para RGB: necessario porque PNGs com canal alpha, HEIC ou
           imagens em escala de cinza nao podem ser salvas diretamente como JPEG.
        3. Redimensiona se o maior lado exceder `MAX_IMAGE_SIZE`. Mantem aspect
           ratio.
        4. Reencoda como JPEG com qualidade `JPEG_QUALITY` e `optimize=True`.
    
    Args:
        image_bytes: Bytes da imagem original recebida do cliente (qualquer formato
            suportado pelo Pillow: JPEG, PNG, HEIC, WEBP, etc).
    
    Returns:
        Bytes da imagem otimizada em formato JPEG, pronta para envio ao Gemini.
    
    Raises:
        ValueError: Se os bytes nao representam uma imagem valida.
    """
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
    """
    Extrai dados estruturados (titulo, valor, categoria) de uma imagem de
    comprovante usando o Gemini Vision.
    
    Fluxo:
        1. Valida que o cliente Gemini esta configurado.
        2. Preprocessa a imagem (ver `_preprocessar_imagem`).
        3. Monta a requisicao (ver `_montar_config`) com o prompt em
           `system_instruction` e apenas a imagem no `contents`, mantendo o
           payload por requisicao minimo.
        4. Le `response.parsed` (objeto `GastoExtraido` ja validado pelo Pydantic).
        5. Trunca o titulo em 40 caracteres como camada extra de seguranca.
    
    Args:
        image_bytes: Bytes brutos da imagem do comprovante.
    
    Returns:
        dict com chaves:
            - "titulo" (str): Nome do estabelecimento/gasto, max 40 chars.
            - "valor" (float): Valor total pago em BRL, arredondado a 2 casas.
            - "categoria" (str): Valor do enum Categoria (ALIMENTACAO, etc).
    
    Raises:
        ValueError: Se a API key nao esta configurada, a imagem e invalida, ou
            o modelo nao conseguiu retornar dados estruturados.
    """
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
