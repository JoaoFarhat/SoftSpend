"""Geracao dos relatorios de gastos de um ciclo (CSV e PDF).

O PDF e montado em memoria e devolvido ao client; nada e persistido no bucket.
As miniaturas dos comprovantes sao baixadas em paralelo, porque o gargalo do
export e a latencia do S3, nao a CPU de montar o documento.
"""

import csv
import io
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from decimal import Decimal

from reportlab.lib import colors
from reportlab.lib.enums import TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.platypus import (
    Image,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

import models
from services import storage_service

logger = logging.getLogger(__name__)

COMPROVANTE_IMAGEM = "imagem"
COMPROVANTE_LINK = "link"
COMPROVANTE_NENHUM = "nenhum"

MAX_DOWNLOADS_PARALELOS = 8

# Altura maxima da miniatura na linha da tabela.
COMPROVANTE_ALTURA_MAX = 32 * mm
COMPROVANTE_LARGURA_MAX = 34 * mm

ROTULOS_CATEGORIA = {
    "ALIMENTACAO": "Alimentação",
    "TRANSPORTE": "Transporte",
    "LAZER": "Lazer",
    "COMPRAS": "Compras",
    "OUTROS": "Outros",
}


def _rotulo_categoria(categoria) -> str:
    nome = getattr(categoria, "name", None) or str(categoria or "")
    return ROTULOS_CATEGORIA.get(nome, nome.title() if nome else "-")


def _moeda(valor: Decimal | None) -> str:
    """Formata em pt-BR sem depender de locale instalado no sistema."""
    numero = Decimal(valor or 0)
    inteiro, _, centavos = f"{numero:.2f}".partition(".")
    negativo = inteiro.startswith("-")
    inteiro = inteiro.lstrip("-")

    grupos = []
    while len(inteiro) > 3:
        grupos.insert(0, inteiro[-3:])
        inteiro = inteiro[:-3]
    grupos.insert(0, inteiro)

    return f"{'-' if negativo else ''}R$ {'.'.join(grupos)},{centavos}"


def _data(valor: datetime | None) -> str:
    return valor.strftime("%d/%m/%Y") if valor else "-"


def _dias_ordenados(ciclo: models.Ciclo) -> list[models.Dia]:
    return sorted(ciclo.dias or [], key=lambda d: (d.data is None, d.data))


def _gastos_do_dia(dia: models.Dia) -> list[models.Gasto]:
    return sorted(dia.gastos or [], key=lambda g: g.id or 0)


def nome_arquivo(ciclo: models.Ciclo, formato: str) -> str:
    titulo = "".join(
        caractere if caractere.isalnum() or caractere in "-_" else "-"
        for caractere in (ciclo.titulo or "ciclo")
    ).strip("-") or "ciclo"
    return f"gastos-{titulo.lower()}-{ciclo.id}.{formato}"


def gerar_csv(ciclo: models.Ciclo) -> bytes:
    """Uma linha por gasto, com o dia repetido para facilitar filtro/pivot.

    Usa `;` e BOM porque o Excel em pt-BR abre CSV com virgula numa unica coluna
    e perde os acentos sem o BOM.
    """
    buffer = io.StringIO()
    writer = csv.writer(buffer, delimiter=";", quoting=csv.QUOTE_MINIMAL)

    writer.writerow(["Ciclo", ciclo.titulo or "-"])
    writer.writerow(["Periodo", ciclo.periodo or "-"])
    writer.writerow(["Valor total", f"{Decimal(ciclo.valor_total or 0):.2f}"])
    writer.writerow(["Gasto total", f"{Decimal(ciclo.gasto_total or 0):.2f}"])
    writer.writerow(["Diaria", f"{Decimal(ciclo.diaria or 0):.2f}"])
    writer.writerow([])
    writer.writerow(["Data", "Saldo do dia", "Titulo", "Categoria", "Valor", "Tem comprovante"])

    for dia in _dias_ordenados(ciclo):
        saldo = f"{Decimal(dia.saldo or 0):.2f}"
        for gasto in _gastos_do_dia(dia):
            writer.writerow([
                _data(dia.data),
                saldo,
                gasto.titulo or "-",
                _rotulo_categoria(gasto.categoria),
                f"{Decimal(gasto.valor or 0):.2f}",
                "sim" if gasto.comprovante_key else "nao",
            ])

    return buffer.getvalue().encode("utf-8-sig")


def _baixar_thumbs(ciclo: models.Ciclo) -> dict[str, bytes]:
    """Baixa as miniaturas em paralelo, indexadas por comprovante_key."""
    keys = [
        gasto.comprovante_key
        for dia in _dias_ordenados(ciclo)
        for gasto in _gastos_do_dia(dia)
        if gasto.comprovante_key
    ]

    if not keys or not storage_service.esta_configurado():
        return {}

    with ThreadPoolExecutor(max_workers=min(MAX_DOWNLOADS_PARALELOS, len(keys))) as pool:
        resultados = pool.map(storage_service.carregar_thumb, keys)

    return {key: dados for key, dados in zip(keys, resultados) if dados}


def _celula_comprovante(gasto: models.Gasto, thumbs: dict[str, bytes], modo: str, estilos):
    if modo == COMPROVANTE_NENHUM or not gasto.comprovante_key:
        return Paragraph("-", estilos["celula"])

    if modo == COMPROVANTE_LINK:
        url = storage_service.url_do_comprovante(gasto.comprovante_key)
        if not url:
            return Paragraph("-", estilos["celula"])
        rotulo = "Ver PDF" if storage_service.e_pdf(gasto.comprovante_key) else "Ver imagem"
        return Paragraph(f'<link href="{url}" color="blue">{rotulo}</link>', estilos["celula"])

    dados = thumbs.get(gasto.comprovante_key)
    if not dados:
        return Paragraph("(indisponível)", estilos["celula"])

    try:
        leitor = ImageReader(io.BytesIO(dados))
        largura, altura = leitor.getSize()
        escala = min(COMPROVANTE_LARGURA_MAX / largura, COMPROVANTE_ALTURA_MAX / altura)
        imagem = Image(io.BytesIO(dados), width=largura * escala, height=altura * escala)
    except Exception as erro:
        logger.warning(
            "Falha ao embutir comprovante %s: %s", gasto.comprovante_key, type(erro).__name__
        )
        return Paragraph("(indisponível)", estilos["celula"])

    url = storage_service.url_do_comprovante(gasto.comprovante_key)
    if not url:
        return imagem

    # A imagem garante o valor probatorio; o link e conveniencia e expira junto
    # com a URL pre-assinada.
    return [imagem, Paragraph(f'<link href="{url}" color="blue">original</link>', estilos["mini"])]


def _estilos():
    base = getSampleStyleSheet()
    return {
        "titulo": ParagraphStyle("titulo", parent=base["Title"], fontSize=18, spaceAfter=2),
        "subtitulo": ParagraphStyle("subtitulo", parent=base["Normal"], fontSize=9, textColor=colors.HexColor("#666666")),
        "cabecalho": ParagraphStyle("cabecalho", parent=base["Normal"], fontSize=8, textColor=colors.white),
        "celula": ParagraphStyle("celula", parent=base["Normal"], fontSize=8, leading=10),
        "celulaNegrito": ParagraphStyle("celulaNegrito", parent=base["Normal"], fontSize=8, leading=10, fontName="Helvetica-Bold"),
        "valor": ParagraphStyle("valor", parent=base["Normal"], fontSize=8, alignment=TA_RIGHT),
        "mini": ParagraphStyle("mini", parent=base["Normal"], fontSize=6, textColor=colors.HexColor("#666666")),
    }


def _tabela_resumo(ciclo: models.Ciclo, total_gastos: int, estilos) -> Table:
    dados = [[
        Paragraph("<b>Total de gastos</b><br/>" + _moeda(ciclo.gasto_total), estilos["celula"]),
        Paragraph(f"<b>Quantidade</b><br/>{total_gastos}", estilos["celula"]),
        Paragraph("<b>Valor previsto</b><br/>" + _moeda(ciclo.valor_total), estilos["celula"]),
        Paragraph("<b>Diária</b><br/>" + _moeda(ciclo.diaria), estilos["celula"]),
    ]]
    tabela = Table(dados, colWidths=[45 * mm] * 4)
    tabela.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F4F6F5")),
        ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#DDDDDD")),
        ("INNERGRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#DDDDDD")),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    return tabela


def gerar_pdf(ciclo: models.Ciclo, comprovantes: str = COMPROVANTE_IMAGEM) -> bytes:
    estilos = _estilos()
    thumbs = _baixar_thumbs(ciclo) if comprovantes == COMPROVANTE_IMAGEM else {}

    larguras = [10 * mm, 20 * mm, 55 * mm, 25 * mm, 25 * mm, 36 * mm]
    linhas = [[
        Paragraph("#", estilos["cabecalho"]),
        Paragraph("DATA", estilos["cabecalho"]),
        Paragraph("DESCRIÇÃO", estilos["cabecalho"]),
        Paragraph("CATEGORIA", estilos["cabecalho"]),
        Paragraph("VALOR", estilos["cabecalho"]),
        Paragraph("COMPROVANTE", estilos["cabecalho"]),
    ]]

    estilo_tabela = [
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F7A63")),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (4, 0), (4, -1), "RIGHT"),
        ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#DDDDDD")),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]

    indice = 0
    totais_categoria: dict[str, Decimal] = {}

    for dia in _dias_ordenados(ciclo):
        gastos = _gastos_do_dia(dia)
        if not gastos:
            continue

        # Cabecalho do agrupamento por dia, mesclado na largura da tabela.
        linha_dia = len(linhas)
        linhas.append([
            Paragraph(
                f"<b>{_data(dia.data)}</b> &nbsp;·&nbsp; saldo do dia: {_moeda(dia.saldo)}",
                estilos["celula"],
            ),
            "", "", "", "", "",
        ])
        estilo_tabela += [
            ("SPAN", (0, linha_dia), (-1, linha_dia)),
            ("BACKGROUND", (0, linha_dia), (-1, linha_dia), colors.HexColor("#EDF3F1")),
        ]

        for gasto in gastos:
            indice += 1
            rotulo = _rotulo_categoria(gasto.categoria)
            totais_categoria[rotulo] = totais_categoria.get(rotulo, Decimal(0)) + Decimal(
                gasto.valor or 0
            )

            linhas.append([
                Paragraph(str(indice), estilos["celula"]),
                Paragraph(_data(dia.data), estilos["celula"]),
                Paragraph(gasto.titulo or "-", estilos["celulaNegrito"]),
                Paragraph(rotulo, estilos["celula"]),
                Paragraph(_moeda(gasto.valor), estilos["valor"]),
                _celula_comprovante(gasto, thumbs, comprovantes, estilos),
            ])

    if indice == 0:
        linhas.append([Paragraph("Nenhum gasto lançado neste ciclo.", estilos["celula"]), "", "", "", "", ""])
        estilo_tabela.append(("SPAN", (0, 1), (-1, 1)))

    tabela = Table(linhas, colWidths=larguras, repeatRows=1)
    tabela.setStyle(TableStyle(estilo_tabela))

    elementos = [
        Paragraph("RELATÓRIO DE GASTOS", estilos["titulo"]),
        Paragraph(
            f"{ciclo.titulo or '-'} &nbsp;·&nbsp; {ciclo.periodo or '-'} &nbsp;·&nbsp; "
            f"gerado em {datetime.now().strftime('%d/%m/%Y %H:%M')}",
            estilos["subtitulo"],
        ),
        Spacer(1, 8 * mm),
        _tabela_resumo(ciclo, indice, estilos),
        Spacer(1, 6 * mm),
        tabela,
    ]

    if totais_categoria:
        resumo = [[
            Paragraph("<b>Categoria</b>", estilos["celula"]),
            Paragraph("<b>Total</b>", estilos["valor"]),
        ]]
        for rotulo, total in sorted(totais_categoria.items(), key=lambda item: -item[1]):
            resumo.append([
                Paragraph(rotulo, estilos["celula"]),
                Paragraph(_moeda(total), estilos["valor"]),
            ])

        tabela_resumo = Table(resumo, colWidths=[100 * mm, 40 * mm])
        tabela_resumo.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#DDDDDD")),
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EDF3F1")),
            ("ALIGN", (1, 0), (1, -1), "RIGHT"),
        ]))
        elementos += [Spacer(1, 6 * mm), Paragraph("<b>Total por categoria</b>", estilos["celula"]), Spacer(1, 2 * mm), tabela_resumo]

    buffer = io.BytesIO()
    documento = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=12 * mm,
        rightMargin=12 * mm,
        topMargin=14 * mm,
        bottomMargin=14 * mm,
        title=f"Relatório de gastos - {ciclo.titulo or ciclo.id}",
    )
    documento.build(elementos, onLaterPages=_rodape, onFirstPage=_rodape)
    return buffer.getvalue()


def _rodape(canvas, documento):
    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(colors.HexColor("#888888"))
    canvas.drawString(12 * mm, 8 * mm, "SoftSpend")
    canvas.drawRightString(A4[0] - 12 * mm, 8 * mm, f"Página {documento.page}")
    canvas.restoreState()
