"""
ocr_service.py
==============

Servico de extracao automatica de dados a partir de comprovantes/notas fiscais
brasileiras usando o modelo Gemini 2.5 Flash da Google (multimodal).

"""

import os
from io import BytesIO

from google import genai
from google.genai import types
from PIL import Image, ImageOps
from pydantic import BaseModel

from enums.categoria_enum import Categoria

# Chave da API lida do ambiente (nunca commitar no codigo)
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
MODEL_NAME = "gemini-2.5-flash"

# Limite maximo de dimensao da imagem (maior lado). Imagens maiores sao redimensionadas.
# 1280px e suficiente para OCR de comprovantes mantendo legibilidade.
MAX_IMAGE_SIZE = 1280

# Qualidade JPEG no recompactamento (85 mantem texto legivel com boa compressao).
JPEG_QUALITY = 85

# Cliente Gemini criado uma unica vez (singleton no escopo do modulo).
# Se a API key nao estiver configurada, o cliente e None e o servico falha de
# forma controlada na primeira chamada de extracao.
_client = genai.Client(api_key=GEMINI_API_KEY) if GEMINI_API_KEY else None


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


PROMPT = """Voce e um sistema fintech especializado em extrair dados de comprovantes, notas fiscais e cupons fiscais brasileiros com precisao maxima.

REGRAS DE EXTRACAO:

1. TITULO (max 40 caracteres):
   - Use o NOME do estabelecimento quando visivel (razao social ou nome fantasia)
   - Se houver descricao do servico/produto principal, prefixe (ex: "Almoco - Restaurante X")
   - Para apps de entrega (iFood, Rappi), use "<App> - <Restaurante>"
   - Para transporte (Uber, 99), use o nome do app + tipo se possivel (ex: "Uber - UberX")
   - Capitalize corretamente (Title Case), nunca tudo maiusculo

2. VALOR (em BRL):
   - Extraia o VALOR TOTAL pago (apos descontos, com taxas)
   - Procure rotulos: "TOTAL", "VALOR TOTAL", "VALOR PAGO", "VLR PAGO", "TOTAL R$"
   - NUNCA confunda com subtotal, troco, ou valor de itens individuais
   - Use ponto como separador decimal (ex: 45.90, nao 45,90)
   - Se houver multiplos valores, use o MAIOR que aparece como total final

3. CATEGORIA (escolha UMA):
   - ALIMENTACAO: restaurantes, lanchonetes, supermercados, padarias, iFood, Rappi, mercados, acougues, hortifruti, bares (foco comida)
   - TRANSPORTE: Uber, 99, taxi, gasolina/combustivel, posto, onibus, metro, estacionamento, pedagio, lavagem de carro, mecanica
   - LAZER: cinema, teatro, shows, parques, jogos, streaming (Netflix, Spotify), boates, bares (foco bebida/festa)
   - COMPRAS: roupas, calcados, eletronicos, livros, farmacias, perfumarias, moveis, lojas de departamento, e-commerce (Amazon, Mercado Livre)
   - OUTROS: contas (luz, agua, internet), saude, educacao, qualquer outro

EXEMPLOS:
- Cupom "BURGER KING - TOTAL R$ 35,90" -> {"titulo": "Burger King", "valor": 35.90, "categoria": "ALIMENTACAO"}
- Recibo "UBER - VIAGEM R$ 18,50" -> {"titulo": "Uber - Viagem", "valor": 18.50, "categoria": "TRANSPORTE"}
- Nota "DROGARIA SAO PAULO - TOTAL 87,30" -> {"titulo": "Drogaria Sao Paulo", "valor": 87.30, "categoria": "COMPRAS"}

Se a imagem estiver ilegivel ou nao for um comprovante, retorne titulo="Gasto", valor=0, categoria="OUTROS".
"""


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
        3. Monta a requisicao com:
           - `temperature=0.0`: respostas deterministicas (mesma imagem -> mesmo
             resultado), reduz alucinacoes.
           - `response_mime_type="application/json"` + `response_schema`: forca
             o modelo a retornar JSON valido conforme o schema, eliminando
             parsing fragil.
           - `thinking_budget=0`: desativa o raciocinio interno do gemini-2.5.
             Para extracao estruturada baseada em prompt detalhado, o thinking
             nao agrega qualidade.
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

    imagem_otimizada = _preprocessar_imagem(image_bytes)
    imagem_part = types.Part.from_bytes(data=imagem_otimizada, mime_type="image/jpeg")

    response = _client.models.generate_content(
        model=MODEL_NAME,
        contents=[PROMPT, imagem_part],
        config=types.GenerateContentConfig(
            temperature=0.0,
            response_mime_type="application/json",
            response_schema=GastoExtraido,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
        ),
    )

    dados: GastoExtraido = response.parsed
    if dados is None:
        raise ValueError(f"Modelo nao retornou dados estruturados: {response.text}")

    return {
        "titulo": dados.titulo[:40],
        "valor": round(dados.valor, 2),
        "categoria": dados.categoria.value,
    }
