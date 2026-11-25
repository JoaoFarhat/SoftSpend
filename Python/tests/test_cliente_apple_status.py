"""`ClienteApple.status` só usa a compra pedida.

Num grupo com outra compra (ex.: Compartilhamento Familiar), o item cujo
`originalTransactionId` não é o pedido não pode virar o estado gravado na
linha do usuário. O `AppStoreServerAPIClient` real é montado em
`ClienteApple._novo_cliente`, substituído aqui por um cliente falso que
devolve objetos com `data[].lastTransactions[]`; `obter_verificador` é
trocado por um verificador falso. Nenhum teste chama a Apple.
"""

from types import SimpleNamespace

import pytest
from appstoreserverlibrary.api_client import APIException

from services import apple_service
from services.apple_service import (
    AppleIndisponivel,
    ClienteApple,
    Renovacao,
    Transacao,
)


# ------------------------------------------------------------------ fakes


class _ApiFalsa:
    """`AppStoreServerAPIClient` falso: devolve a resposta ou levanta o erro."""

    def __init__(self):
        self.resposta = SimpleNamespace(data=[])
        self.erro: Exception | None = None
        self.consultas: list[str] = []

    def get_all_subscription_statuses(self, original_transaction_id):
        self.consultas.append(original_transaction_id)
        if self.erro is not None:
            raise self.erro
        return self.resposta


class _VerificadorFalso:
    """Decodifica os JWS falsos registrados (a chave é a própria string)."""

    def __init__(self):
        self.transacoes: dict[str, Transacao] = {}
        self.renovacoes: dict[str, Renovacao] = {}
        self.verificados: list[str] = []

    def verificar_transacao(self, jws):
        self.verificados.append(jws)
        return self.transacoes[jws]

    def verificar_renovacao(self, jws):
        return self.renovacoes[jws]


def _item(original_transaction_id, jws=None, renovacao=None, status=1):
    return SimpleNamespace(
        originalTransactionId=original_transaction_id,
        signedTransactionInfo=jws or f"jws-{original_transaction_id}",
        signedRenewalInfo=renovacao,
        status=status,
    )


def _grupo(*itens):
    return SimpleNamespace(lastTransactions=list(itens))


def _resposta(*grupos):
    return SimpleNamespace(data=list(grupos))


@pytest.fixture
def ambiente(monkeypatch):
    api = _ApiFalsa()
    verificador = _VerificadorFalso()
    monkeypatch.setattr(apple_service, "obter_verificador", lambda amb: verificador)

    class _ClienteTestavel(ClienteApple):
        def _novo_cliente(self):
            return api

    return SimpleNamespace(
        cliente=_ClienteTestavel("Production"), api=api, verificador=verificador
    )


# ------------------------------------------------------------------ testes


def test_status_usa_o_item_da_compra_pedida(ambiente):
    """Dois itens no grupo, o pedido em segundo: o primeiro é ignorado."""
    tx = Transacao(original_transaction_id="otid-2", transaction_id="t-2")
    ambiente.verificador.transacoes["jws-2"] = tx
    ambiente.verificador.renovacoes["ren-2"] = Renovacao(renovacao_automatica=True)
    ambiente.api.resposta = _resposta(
        _grupo(
            _item("otid-1", status=1),
            _item("otid-2", jws="jws-2", renovacao="ren-2", status=2),
        )
    )

    estado = ambiente.cliente.status("otid-2")

    assert estado is not None
    assert estado.status == 2
    assert estado.transacao is tx
    assert estado.renovacao.renovacao_automatica is True
    assert ambiente.verificador.verificados == ["jws-2"]


def test_status_sem_item_da_compra_devolve_none(ambiente):
    """O grupo só traz outra compra: sem estado, sem decodificar nada."""
    ambiente.api.resposta = _resposta(_grupo(_item("otid-1")))
    assert ambiente.cliente.status("otid-2") is None
    assert ambiente.verificador.verificados == []


def test_status_404_devolve_none(ambiente):
    ambiente.api.erro = APIException(404)
    assert ambiente.cliente.status("otid-x") is None


def test_status_500_apple_indisponivel(ambiente):
    ambiente.api.erro = APIException(500)
    with pytest.raises(AppleIndisponivel):
        ambiente.cliente.status("otid-x")


def test_status_erro_de_rede_apple_indisponivel(ambiente):
    ambiente.api.erro = OSError("timeout")
    with pytest.raises(AppleIndisponivel):
        ambiente.cliente.status("otid-x")
