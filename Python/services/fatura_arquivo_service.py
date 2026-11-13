"""Leitura de arquivos de fatura de cartão (PDF com senha, OFX e CSV).

Tudo aqui é só leitura: o arquivo nunca vai para disco nem para o S3 e a senha
do PDF nunca é gravada ou logada. Os parsers devolvem a estrutura interna
(`FaturaBruta`), que `montar_fatura_lida` valida e converte no DTO de resposta
— a mesma validação vale para o que veio da IA (não confiamos nela).
"""

import csv
import io
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation

import filetype
from fastapi import UploadFile

from dtos.fatura import MAXIMO_COMPRAS, CompraLida, FaturaLida
from enums.categoria_enum import Categoria

TAMANHO_MAXIMO_PDF = 10 * 1024 * 1024
TAMANHO_MAXIMO_TEXTO = 2 * 1024 * 1024
MAXIMO_PAGINAS_PDF = 20
VALOR_MAXIMO_COMPRA = Decimal("100000")
TOLERANCIA_SOMA = Decimal("0.05")
JANELA_DIAS_ANTES_FECHAMENTO = 40
MAX_AVISOS_DESCARTE = 10

CHUNK_UPLOAD = 64 * 1024

_RE_TAG_OFAX = re.compile(
    r"OFXHEADER|<\s*OFX[\s>]|<STMTTRN>|<BANKTRANLIST>", re.IGNORECASE
)
_RE_PAGAMENTO = re.compile(r"\b(pagamento|pagto|payment)\b", re.IGNORECASE)
_TRNTYPES_ENCARGO = {"FEE", "INT", "SRVCHG"}
_TRNTYPES_PAGAMENTO = {"PAYMENT", "PMT"}


class ErroFatura(Exception):
    """Falha esperada na leitura da fatura, com o HTTP status da resposta."""

    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


@dataclass
class CompraBruta:
    data: date | None
    descricao: str
    valor: Decimal | None
    parcela_atual: int | None = None
    parcela_total: int | None = None
    tipo: str = "COMPRA"
    categoria: Categoria = Categoria.OUTROS
    valor_original: str | None = None


@dataclass
class FaturaBruta:
    emissor: str | None = None
    final_cartao: str | None = None
    fechamento: date | None = None
    vencimento: date | None = None
    total_fatura: Decimal | None = None
    compras: list[CompraBruta] = field(default_factory=list)
    avisos: list[str] = field(default_factory=list)


# ---------------------------------------------------------------- upload


async def ler_upload(arquivo: UploadFile) -> tuple[str, bytes | str]:
    """Lê o upload e detecta o tipo real: "pdf", "ofx" ou "csv".

    PDF é conferido pelos magic bytes; OFX e CSV são texto, conferidos por
    decodificação e cabeçalho. O content-type declarado não é confiável.
    """
    if arquivo.size is not None and arquivo.size > TAMANHO_MAXIMO_PDF:
        raise ErroFatura(413, "Arquivo muito grande (PDF: máx 10MB; OFX/CSV: máx 2MB)")

    conteudo = b""
    while True:
        chunk = await arquivo.read(CHUNK_UPLOAD)
        if not chunk:
            break
        conteudo += chunk
        if len(conteudo) > TAMANHO_MAXIMO_PDF:
            raise ErroFatura(413, "Arquivo muito grande (PDF: máx 10MB; OFX/CSV: máx 2MB)")

    if not conteudo:
        raise ErroFatura(400, "Arquivo vazio")

    kind = filetype.guess(conteudo)
    if kind is not None:
        if kind.mime == "application/pdf":
            return "pdf", conteudo
        raise ErroFatura(400, "Arquivo deve ser um PDF, OFX ou CSV")

    if len(conteudo) > TAMANHO_MAXIMO_TEXTO:
        raise ErroFatura(413, "OFX/CSV muito grande (máx 2MB)")

    texto = _decodificar_texto(conteudo)
    if texto is None:
        raise ErroFatura(400, "Arquivo deve ser um PDF, OFX ou CSV")

    if _RE_TAG_OFAX.search(texto):
        return "ofx", texto
    if _cabecalho_csv_reconhecido(texto):
        return "csv", texto
    raise ErroFatura(422, "Formato não reconhecido; envie o PDF")


def _decodificar_texto(conteudo: bytes) -> str | None:
    # Bytes nulos denunciam um binário que o filetype não conhece.
    if b"\x00" in conteudo[:1024]:
        return None
    try:
        return conteudo.decode("utf-8")
    except UnicodeDecodeError:
        pass
    try:
        return conteudo.decode("cp1252")
    except UnicodeDecodeError:
        return None


# ------------------------------------------------------------------ PDF


def desproteger_pdf(conteudo: bytes, senha: str | None) -> bytes:
    """Abre o PDF (com senha, se preciso), confere o limite de páginas e
    devolve os bytes sem proteção para enviar ao Gemini."""
    import pypdfium2 as pdfium

    documento = None
    protegido = False
    try:
        documento = pdfium.PdfDocument(conteudo)
    except pdfium.PdfiumError as erro:
        if "password" not in str(erro).lower():
            raise ErroFatura(422, "PDF inválido")
        if not senha:
            raise ErroFatura(422, "PDF protegido por senha; informe a senha")
        try:
            documento = pdfium.PdfDocument(conteudo, password=senha)
        except pdfium.PdfiumError:
            raise ErroFatura(422, "Senha incorreta")
        protegido = True

    try:
        paginas = len(documento)
        if paginas == 0:
            raise ErroFatura(422, "PDF sem páginas")
        if paginas > MAXIMO_PAGINAS_PDF:
            raise ErroFatura(413, f"PDF com mais de {MAXIMO_PAGINAS_PDF} páginas")

        if not protegido:
            return conteudo

        # Regrava sem a proteção em memória: importar as páginas num documento
        # novo produz um PDF aberto (doc.save() copiaria a criptografia junto).
        novo = pdfium.PdfDocument.new()
        try:
            novo.import_pages(documento)
            buffer = io.BytesIO()
            novo.save(buffer)
            return buffer.getvalue()
        except pdfium.PdfiumError as erro:
            raise ErroFatura(422, f"Não foi possível processar o PDF: {erro}")
        finally:
            novo.close()
    finally:
        documento.close()


# ------------------------------------------------------------------ OFX


def _tag(bloco: str, nome: str) -> str | None:
    achado = re.search(rf"<{nome}>([^<]+)", bloco, re.IGNORECASE)
    return achado.group(1).strip() if achado else None


def _data_ofx(valor: str | None) -> date | None:
    if not valor:
        return None
    achado = re.match(r"(\d{4})(\d{2})(\d{2})", valor.strip())
    if not achado:
        return None
    try:
        return date(int(achado.group(1)), int(achado.group(2)), int(achado.group(3)))
    except ValueError:
        return None


def _para_decimal(valor: str | None) -> Decimal | None:
    """Aceita '1234.56', '1.234,56', '1234,56' e sinal negativo."""
    if not valor:
        return None
    texto = valor.strip().replace("R$", "").replace(" ", "")
    if not texto:
        return None
    if "," in texto and "." in texto:
        # O separador mais à direita é o decimal.
        if texto.rfind(",") > texto.rfind("."):
            texto = texto.replace(".", "").replace(",", ".")
        else:
            texto = texto.replace(",", "")
    elif "," in texto:
        texto = texto.replace(",", ".")
    try:
        d = Decimal(texto)
    except InvalidOperation:
        return None
    return d if d.is_finite() else None


def ler_ofx(texto: str) -> FaturaBruta:
    """Lê um OFX de fatura de cartão por regex, sem biblioteca nova.

    O sinal de TRNAMT varia por banco: DEBIT/CREDIT definem o tipo; sem
    TRNTYPE, manda o sinal da maioria das transações. Pagamento da fatura
    sai da lista. Nada é enviado à IA.
    """
    fatura = FaturaBruta()

    emissor = _tag(texto, "ORG")
    if emissor:
        fatura.emissor = emissor[:100]
    fatura.fechamento = _data_ofx(_tag(texto, "DTEND"))
    fatura.vencimento = _data_ofx(_tag(texto, "DTASOF"))

    bloco_ledger = re.search(
        r"<LEDGERBAL>(.*?)</LEDGERBAL>", texto, re.IGNORECASE | re.DOTALL
    ) or re.search(r"<LEDGERBAL>(.*)", texto, re.IGNORECASE | re.DOTALL)
    if bloco_ledger:
        total = _para_decimal(_tag(bloco_ledger.group(1), "BALAMT"))
        if total is not None:
            fatura.total_fatura = abs(total)

    transacoes: list[tuple[str | None, Decimal, str, date]] = []
    for bloco in re.split(r"<STMTTRN>", texto, flags=re.IGNORECASE)[1:]:
        bloco = bloco.split("</STMTTRN>")[0]
        trntype = (_tag(bloco, "TRNTYPE") or "").upper() or None
        valor = _para_decimal(_tag(bloco, "TRNAMT"))
        descricao = (_tag(bloco, "MEMO") or _tag(bloco, "NAME") or "").strip()
        data = _data_ofx(_tag(bloco, "DTPOSTED"))
        texto_desc = f"{_tag(bloco, 'NAME') or ''} {_tag(bloco, 'MEMO') or ''}"

        if _RE_PAGAMENTO.search(texto_desc):
            continue
        if trntype in _TRNTYPES_PAGAMENTO:
            continue
        if valor is None or data is None:
            fatura.avisos.append("Lançamento do OFX ignorado por data ou valor ilegível")
            continue
        transacoes.append((trntype, valor, descricao[:200], data))

    negativas = sum(1 for _, v, _, _ in transacoes if v < 0)
    positivas = len(transacoes) - negativas
    sinal_compra = -1 if negativas > positivas else 1

    for trntype, valor, descricao, data in transacoes:
        if trntype == "DEBIT":
            tipo = "COMPRA"
        elif trntype == "CREDIT":
            tipo = "ESTORNO"
        elif trntype in _TRNTYPES_ENCARGO:
            tipo = "ENCARGO"
        else:
            sinal = -1 if valor < 0 else 1
            tipo = "COMPRA" if sinal == sinal_compra else "ESTORNO"
        fatura.compras.append(
            CompraBruta(data=data, descricao=descricao, valor=abs(valor), tipo=tipo)
        )

    return fatura


# ------------------------------------------------------------------ CSV


def _normalizar_coluna(coluna: str) -> str:
    texto = unicodedata.normalize("NFKD", coluna)
    texto = "".join(c for c in texto if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", texto.lower())


_COLUNAS_DATA = {
    "data", "date", "datacompra", "datalancamento", "dtposted",
    "postingdate", "transactiondate",
}
_COLUNAS_DESCRICAO = {
    "descricao", "description", "title", "titulo", "estabelecimento",
    "merchant", "memo", "name", "historico", "lancamento", "detalhe",
    "detalhes", "local",
}
_COLUNAS_VALOR = {
    "valor", "amount", "value", "total", "valortotal", "valordacompra",
    "valorr", "valorreais", "valorbrl", "preco", "montante",
}


def _colunas_csv(texto: str) -> tuple[str, list[str]] | None:
    """Devolve (separador, colunas normalizadas) da primeira linha não vazia."""
    for linha in texto.splitlines():
        if linha.strip():
            separador = ";" if linha.count(";") >= linha.count(",") else ","
            try:
                colunas = next(csv.reader([linha], delimiter=separador))
            except csv.Error:
                return None
            return separador, [_normalizar_coluna(c) for c in colunas]
    return None


def _cabecalho_csv_reconhecido(texto: str) -> bool:
    achado = _colunas_csv(texto)
    if not achado:
        return False
    _, colunas = achado
    return (
        any(c in _COLUNAS_DATA for c in colunas)
        and any(c in _COLUNAS_DESCRICAO for c in colunas)
        and any(c in _COLUNAS_VALOR for c in colunas)
    )


def _data_csv(valor: str | None) -> date | None:
    if not valor:
        return None
    texto = valor.strip()
    for formato in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%d/%m/%y"):
        try:
            from datetime import datetime

            return datetime.strptime(texto, formato).date()
        except ValueError:
            continue
    return None


def ler_csv(texto: str) -> FaturaBruta:
    """Lê um CSV simples (colunas reconhecíveis de data, descrição e valor,
    separador ',' ou ';', decimal com vírgula ou ponto). Nada vai à IA."""
    achado = _colunas_csv(texto)
    if not achado:
        raise ErroFatura(422, "Formato não reconhecido; envie o PDF")
    separador, colunas = achado

    def _indice(possiveis: set[str]) -> int | None:
        for i, coluna in enumerate(colunas):
            if coluna in possiveis:
                return i
        return None

    i_data = _indice(_COLUNAS_DATA)
    i_desc = _indice(_COLUNAS_DESCRICAO)
    i_valor = _indice(_COLUNAS_VALOR)
    if i_data is None or i_desc is None or i_valor is None:
        raise ErroFatura(422, "Formato não reconhecido; envie o PDF")

    fatura = FaturaBruta()
    linhas = [l for l in texto.splitlines() if l.strip()]
    ignoradas = 0
    leitor = csv.reader(linhas[1:], delimiter=separador)
    for campos in leitor:
        if len(campos) <= max(i_data, i_desc, i_valor):
            ignoradas += 1
            continue
        descricao = campos[i_desc].strip()
        if _RE_PAGAMENTO.search(descricao):
            continue
        valor = _para_decimal(campos[i_valor])
        if valor is None:
            ignoradas += 1
            continue
        tipo = "COMPRA" if valor >= 0 else "ESTORNO"
        fatura.compras.append(
            CompraBruta(
                data=_data_csv(campos[i_data]),
                descricao=descricao[:200],
                valor=abs(valor),
                tipo=tipo,
            )
        )

    if ignoradas:
        fatura.avisos.append(
            f"{ignoradas} linha(s) do CSV ignorada(s) por dados ilegíveis"
        )
    return fatura


# ----------------------------------------------------- validação e DTO


def _motivo_descarte(
    compra: CompraBruta, limite_inferior: date | None, vencimento: date | None
) -> str | None:
    if compra.valor is None or compra.valor <= 0 or compra.valor > VALOR_MAXIMO_COMPRA:
        return "valor inválido"
    if not compra.descricao or not compra.descricao.strip():
        return "descrição vazia"
    if compra.data is None:
        return "data inválida"
    if limite_inferior and compra.data < limite_inferior:
        return "data fora do período da fatura"
    if vencimento and compra.data > vencimento:
        return "data fora do período da fatura"
    return None


def montar_fatura_lida(bruta: FaturaBruta) -> FaturaLida:
    """Valida o que veio da IA/OFX/CSV e monta o DTO da prévia.

    A IA é tratada como não confiável: lançamento com data fora de
    [fechamento - 40 dias, vencimento], valor <= 0 ou acima de R$ 100.000,
    ou descrição vazia é descartado com aviso. `soma_confere` compara
    compras + encargos - estornos com o total (tolerância R$ 0,05).
    """
    avisos = list(bruta.avisos)
    limite_inferior = (
        bruta.fechamento - timedelta(days=JANELA_DIAS_ANTES_FECHAMENTO)
        if bruta.fechamento
        else None
    )

    validas: list[CompraBruta] = []
    descartadas = 0
    for compra in bruta.compras:
        motivo = _motivo_descarte(compra, limite_inferior, bruta.vencimento)
        if motivo is None:
            validas.append(compra)
            continue
        descartadas += 1
        if descartadas <= MAX_AVISOS_DESCARTE:
            rotulo = compra.descricao.strip()[:40] or "sem descrição"
            avisos.append(f"Lançamento '{rotulo}' ignorado: {motivo}")
    if descartadas > MAX_AVISOS_DESCARTE:
        avisos.append(f"... e mais {descartadas - MAX_AVISOS_DESCARTE} lançamentos ignorados")

    if len(validas) > MAXIMO_COMPRAS:
        avisos.append(
            f"Fatura com mais de {MAXIMO_COMPRAS} compras; só as primeiras foram lidas"
        )
        validas = validas[:MAXIMO_COMPRAS]

    soma_confere = None
    diferenca = None
    if bruta.total_fatura is not None:
        soma = Decimal("0")
        for compra in validas:
            if compra.tipo == "ESTORNO":
                soma -= compra.valor
            else:
                soma += compra.valor
        diferenca = (soma - bruta.total_fatura).quantize(Decimal("0.01"))
        soma_confere = abs(diferenca) <= TOLERANCIA_SOMA
        if not soma_confere:
            avisos.append(
                "Não consegui ler tudo: confira a lista (a soma não bate com o total da fatura)"
            )

    return FaturaLida(
        emissor=bruta.emissor,
        final_cartao=bruta.final_cartao,
        fechamento=bruta.fechamento,
        vencimento=bruta.vencimento,
        total_fatura=bruta.total_fatura,
        soma_confere=soma_confere,
        diferenca=diferenca,
        avisos=avisos,
        compras=[
            CompraLida(
                indice=i,
                data=c.data,
                descricao=c.descricao.strip(),
                valor=c.valor,
                parcela_atual=c.parcela_atual,
                parcela_total=c.parcela_total,
                tipo=c.tipo,
                categoria=c.categoria,
                valor_original=c.valor_original,
            )
            for i, c in enumerate(validas)
        ],
    )
