"""Valores extremos na leitura da fatura (CSV, OFX ou IA).

Dois valores extremos davam dado errado ou 500 no `POST /api/faturas/ler`:

- uma compra de 0,004 passava no "valor > 0" (a checagem rodava antes do
  arredondamento) e entrava na prévia e no banco como R$ 0,00;
- um `total_fatura` com mais de ~26 dígitos inteiros quebrava o
  `quantize` (`InvalidOperation`).

`_valor_lido` agora confere `None` e o teto antes de arredondar (2
casas, `ROUND_HALF_UP`) e só então exige valor > 0 — a compra que
arredonda para 0,00 é descartada como "valor inválido". Total acima de
`VALOR_MAXIMO_COMPRA * MAXIMO_COMPRAS` vira None (`soma_confere` e
`diferenca` ficam None) com aviso, sem exceção. Testes diretos em
`montar_fatura_lida`, sem rota.
"""

from datetime import date
from decimal import Decimal

from services.fatura_arquivo_service import (
    CompraBruta,
    FaturaBruta,
    montar_fatura_lida,
)


def _compra(valor: str, descricao: str = "Loja", data: date = date(2026, 10, 1)):
    return CompraBruta(data=data, descricao=descricao, valor=Decimal(valor))


def test_compra_que_arredonda_para_zero_eh_descartada():
    lida = montar_fatura_lida(FaturaBruta(compras=[_compra("0.004")]))

    assert lida.compras == []
    assert any("valor inválido" in aviso for aviso in lida.avisos)


def test_compra_de_meio_centavo_entra_como_um_centavo():
    lida = montar_fatura_lida(FaturaBruta(compras=[_compra("0.005")]))

    assert [c.valor for c in lida.compras] == [Decimal("0.01")]


def test_total_gigante_nao_lanca_e_vira_none_com_aviso():
    """1e40 estourava o quantize do total (InvalidOperation → 500). Agora
    vira None com aviso e as compras seguem valendo."""
    lida = montar_fatura_lida(
        FaturaBruta(
            total_fatura=Decimal("1e40"),
            compras=[_compra("10.00")],
        )
    )

    assert lida.total_fatura is None
    assert lida.soma_confere is None
    assert lida.diferenca is None
    assert "Total da fatura ilegível; confira a lista" in lida.avisos
    assert [c.valor for c in lida.compras] == [Decimal("10.00")]


def test_fatura_normal_sai_igual_a_antes():
    bruta = FaturaBruta(
        emissor="Banco",
        fechamento=date(2026, 10, 7),
        vencimento=date(2026, 10, 20),
        total_fatura=Decimal("100.00"),
        compras=[
            _compra("60.00", "Supermercado"),
            _compra("40.00", "Farmácia", date(2026, 10, 2)),
        ],
    )

    lida = montar_fatura_lida(bruta)

    assert [c.descricao for c in lida.compras] == ["Supermercado", "Farmácia"]
    assert [c.valor for c in lida.compras] == [Decimal("60.00"), Decimal("40.00")]
    assert lida.total_fatura == Decimal("100.00")
    assert lida.soma_confere is True
    assert lida.diferenca == Decimal("0.00")
    assert lida.avisos == []
