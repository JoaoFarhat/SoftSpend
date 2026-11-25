"""Separador de milhar e centavos na leitura de fatura (CSV/OFX).

Uma compra de R$ 1.500 num CSV brasileiro era lida como R$ 1,50 — "1.500"
(caía no ramo decimal) — e um valor com 3 casas ("12.345") passava sem
arredondar para o `CompraLida` (o `Dinheiro` do DTO não arredonda), então
o gasto criado no app saía diferente do que o servidor gravava.
`_para_decimal` agora trata grupos de 3 dígitos como milhar e
`montar_fatura_lida` quantiza tudo em 2 casas antes da soma e do DTO.
Testes diretos nas funções, sem rota.
"""

from datetime import date
from decimal import Decimal

import pytest

from services.fatura_arquivo_service import (
    CompraBruta,
    FaturaBruta,
    _para_decimal,
    ler_csv,
    ler_ofx,
    montar_fatura_lida,
)


@pytest.mark.parametrize(
    "texto, esperado",
    [
        ("1.500", "1500"),
        ("R$ 2.300.000", "2300000"),
        ("-1.500", "-1500"),
        ("1,500", "1500"),
        ("12.50", "12.50"),
        ("1.234,56", "1234.56"),
        ("1,234.56", "1234.56"),
        # Começa com 0: não casa com a regra de milhar, segue decimal.
        ("0.500", "0.500"),
    ],
)
def test_para_decimal_milhar(texto, esperado):
    assert _para_decimal(texto) == Decimal(esperado)


def test_csv_valor_com_ponto_de_milhar():
    fatura = ler_csv("data;descricao;valor\n01/10/2026;Hotel;1.500\n")
    assert len(fatura.compras) == 1
    assert fatura.compras[0].valor == Decimal("1500")

    lida = montar_fatura_lida(fatura)
    assert lida.compras[0].valor == Decimal("1500.00")


def _ofx(trnamt: str) -> str:
    return "\n".join(
        [
            "OFXHEADER:100",
            "<OFX>",
            "<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL",
            "<BANKTRANLIST><DTSTART>20260901000000<DTEND>20261007000000",
            f"<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261001000000"
            f"<TRNAMT>{trnamt}<FITID>t0<MEMO>Hotel</STMTTRN>",
            "</BANKTRANLIST>",
            "</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>",
        ]
    )


def test_ofx_valor_com_ponto_de_milhar():
    fatura = ler_ofx(_ofx("1.500"))
    assert len(fatura.compras) == 1
    assert fatura.compras[0].valor == Decimal("1500")

    lida = montar_fatura_lida(fatura)
    assert lida.compras[0].valor == Decimal("1500.00")


def test_montar_fatura_lida_arredonda_para_2_casas():
    bruta = FaturaBruta(
        total_fatura=Decimal("12.345"),
        compras=[
            CompraBruta(
                data=date(2026, 10, 1),
                descricao="Loja",
                valor=Decimal("12.345"),
            )
        ],
    )
    lida = montar_fatura_lida(bruta)
    assert lida.compras[0].valor == Decimal("12.35")
    assert lida.total_fatura == Decimal("12.35")
    assert lida.soma_confere is True
