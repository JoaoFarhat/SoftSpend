"""Ponte com a Apple: verificação do JWS e App Store Server API (AS2).

`docs/assinatura.md` §2.1. Tudo o que fala com a biblioteca oficial
(`app-store-server-library`) fica aqui, atrás de duas funções fábrica que os
testes substituem por fakes:

- `obter_verificador(ambiente)` → objeto com `verificar_transacao(jws)`,
  `verificar_renovacao(jws)` e `verificar_notificacao(signed_payload)`;
- `obter_cliente_apple(ambiente)` → objeto com `status(original_transaction_id)`.

O resto do servidor só vê os dataclasses deste módulo (`Transacao`,
`Renovacao`, `Notificacao`, `EstadoApple`), nunca os modelos da biblioteca.
A biblioteca é importada só dentro das implementações reais: nenhum teste
chama a Apple nem precisa de certificado real.

Segredos (`APPLE_PRIVATE_KEY`) nunca vão para log.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

PRODUCTION = "Production"
SANDBOX = "Sandbox"

TIPO_ASSINATURA = "Auto-Renewable Subscription"
PRODUTOS = (
    "br.com.softspend.app.assinatura.mensal",
    "br.com.softspend.app.assinatura.anual",
)

# Códigos do campo `status` de Get All Subscription Statuses.
STATUS_ATIVA = 1
STATUS_EXPIRADA = 2
STATUS_NOVA_TENTATIVA = 3
STATUS_CARENCIA = 4
STATUS_REVOGADA = 5

PASTA_CERTIFICADOS = Path(__file__).resolve().parents[1] / "certificados_apple"


class AppleNaoConfigurada(Exception):
    """Faltam variáveis `APPLE_*` ou os certificados raiz: rotas dão 503."""


class ComprovanteInvalido(Exception):
    """JWS com assinatura, cadeia, app ou ambiente inválidos: 400."""


class AmbienteErrado(ComprovanteInvalido):
    """O JWS é de outro ambiente (Production × Sandbox)."""


class AppleIndisponivel(Exception):
    """A Apple não respondeu (rede, 5xx, OCSP): 503, nada gravado."""


@dataclass
class Transacao:
    original_transaction_id: str
    transaction_id: str | None = None
    bundle_id: str | None = None
    produto: str | None = None
    tipo: str | None = None
    app_account_token: str | None = None
    expira_em: datetime | None = None
    # 1 = oferta introdutória (`offerType`); `FREE_TRIAL` em `offerDiscountType`.
    offer_type: int | None = None
    offer_discount_type: str | None = None
    revogada_em: datetime | None = None
    ambiente: str | None = None
    assinada_em: datetime | None = None


@dataclass
class Renovacao:
    renovacao_automatica: bool | None = None
    carencia_ate: datetime | None = None
    produto_renovacao: str | None = None
    em_nova_tentativa: bool | None = None


@dataclass
class Notificacao:
    uuid: str
    tipo: str
    subtipo: str | None = None
    assinada_em: datetime | None = None
    ambiente: str | None = None
    # `data.status` da notificação (mesmos códigos da API), se veio.
    status: int | None = None
    transacao: Transacao | None = None
    renovacao: Renovacao | None = None


@dataclass
class EstadoApple:
    """O que a App Store Server API diz agora sobre a assinatura."""

    status: int
    transacao: Transacao
    renovacao: Renovacao | None = None


# ---------------------------------------------------------- configuração


def aceita_sandbox() -> bool:
    return os.getenv("APPLE_ACEITA_SANDBOX", "true").strip().lower() != "false"


def _obrigatoria(nome: str) -> str:
    valor = (os.getenv(nome) or "").strip()
    if not valor:
        raise AppleNaoConfigurada(f"{nome} não definida")
    return valor


def _chave_privada() -> bytes:
    conteudo = (os.getenv("APPLE_PRIVATE_KEY") or "").strip()
    if conteudo:
        # No .env a quebra de linha costuma vir como "\n" literal.
        return conteudo.replace("\\n", "\n").encode()
    caminho = (os.getenv("APPLE_PRIVATE_KEY_PATH") or "").strip()
    if not caminho:
        raise AppleNaoConfigurada("APPLE_PRIVATE_KEY não definida")
    try:
        return Path(caminho).read_bytes()
    except OSError as exc:
        raise AppleNaoConfigurada("APPLE_PRIVATE_KEY_PATH ilegível") from exc


def _certificados_raiz() -> list[bytes]:
    arquivos = sorted(PASTA_CERTIFICADOS.glob("*.cer"))
    if not arquivos:
        raise AppleNaoConfigurada("sem certificados raiz em certificados_apple/")
    return [arquivo.read_bytes() for arquivo in arquivos]


def configurada() -> bool:
    """Todas as variáveis `APPLE_*` necessárias existem (não valida a Apple)."""
    try:
        for nome in ("APPLE_BUNDLE_ID", "APPLE_APP_ID", "APPLE_ISSUER_ID", "APPLE_KEY_ID"):
            _obrigatoria(nome)
        _chave_privada()
        _certificados_raiz()
    except AppleNaoConfigurada:
        return False
    return True


# ------------------------------------------------- conversão dos modelos


def _data_ms(valor) -> datetime | None:
    """Datas da Apple vêm em milissegundos UNIX; o banco guarda UTC sem fuso."""
    if valor is None:
        return None
    return datetime.fromtimestamp(int(valor) / 1000, tz=timezone.utc).replace(tzinfo=None)


def _bruto(modelo, campo: str):
    """Valor bruto de um campo de enum (`rawX`) ou o próprio valor."""
    raw = getattr(modelo, "raw" + campo[0].upper() + campo[1:], None)
    if raw is not None:
        return raw
    valor = getattr(modelo, campo, None)
    return getattr(valor, "value", valor)


def transacao_da_biblioteca(payload) -> Transacao:
    """`JWSTransactionDecodedPayload` (camelCase) → `Transacao`."""
    token = getattr(payload, "appAccountToken", None)
    return Transacao(
        original_transaction_id=str(getattr(payload, "originalTransactionId", "") or ""),
        transaction_id=getattr(payload, "transactionId", None),
        bundle_id=getattr(payload, "bundleId", None),
        produto=getattr(payload, "productId", None),
        tipo=_bruto(payload, "type"),
        app_account_token=str(token).lower() if token else None,
        expira_em=_data_ms(getattr(payload, "expiresDate", None)),
        offer_type=_bruto(payload, "offerType"),
        offer_discount_type=_bruto(payload, "offerDiscountType"),
        revogada_em=_data_ms(getattr(payload, "revocationDate", None)),
        ambiente=_bruto(payload, "environment"),
        assinada_em=_data_ms(getattr(payload, "signedDate", None)),
    )


def renovacao_da_biblioteca(payload) -> Renovacao:
    """`JWSRenewalInfoDecodedPayload` → `Renovacao` (`autoRenewStatus` 1 = ligada)."""
    auto = _bruto(payload, "autoRenewStatus")
    return Renovacao(
        renovacao_automatica=None if auto is None else int(auto) == 1,
        carencia_ate=_data_ms(getattr(payload, "gracePeriodExpiresDate", None)),
        produto_renovacao=getattr(payload, "autoRenewProductId", None),
        em_nova_tentativa=getattr(payload, "isInBillingRetryPeriod", None),
    )


# -------------------------------------------------- implementações reais


def _ambiente_biblioteca(ambiente: str):
    from appstoreserverlibrary.models.Environment import Environment

    return Environment.PRODUCTION if ambiente == PRODUCTION else Environment.SANDBOX


class VerificadorApple:
    """`SignedDataVerifier` de um ambiente, com erros traduzidos."""

    def __init__(self, ambiente: str):
        bundle_id = _obrigatoria("APPLE_BUNDLE_ID")
        app_id = _obrigatoria("APPLE_APP_ID")
        certificados = _certificados_raiz()
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

        self.ambiente = ambiente
        self._verificador = SignedDataVerifier(
            certificados,
            True,  # verificações online (OCSP) ligadas nos dois ambientes
            _ambiente_biblioteca(ambiente),
            bundle_id,
            int(app_id),
        )

    def _chamar(self, nome_metodo: str, *nomes_alternativos: str):
        for nome in (nome_metodo, *nomes_alternativos):
            metodo = getattr(self._verificador, nome, None)
            if metodo is not None:
                return metodo
        raise AttributeError(nome_metodo)

    def _decodificar(self, metodo, dado: str):
        from appstoreserverlibrary.signed_data_verifier import (
            VerificationException,
            VerificationStatus,
        )

        try:
            return metodo(dado)
        except VerificationException as exc:
            status = getattr(exc, "status", None)
            if status == VerificationStatus.INVALID_ENVIRONMENT:
                raise AmbienteErrado("ambiente diferente") from None
            if status == getattr(VerificationStatus, "RETRYABLE_VERIFICATION_FAILURE", object()):
                raise AppleIndisponivel("OCSP indisponível") from None
            raise ComprovanteInvalido(str(getattr(status, "name", status))) from None
        except (ValueError, TypeError, KeyError) as exc:
            raise ComprovanteInvalido(type(exc).__name__) from None

    def verificar_transacao(self, jws: str) -> Transacao:
        metodo = self._chamar(
            "verify_and_decode_signed_transaction", "verify_and_decode_transaction"
        )
        return transacao_da_biblioteca(self._decodificar(metodo, jws))

    def verificar_renovacao(self, jws: str) -> Renovacao:
        metodo = self._chamar("verify_and_decode_renewal_info")
        return renovacao_da_biblioteca(self._decodificar(metodo, jws))

    def verificar_notificacao(self, signed_payload: str) -> Notificacao:
        metodo = self._chamar("verify_and_decode_notification")
        payload = self._decodificar(metodo, signed_payload)
        dados = getattr(payload, "data", None)
        transacao = renovacao = None
        status = None
        if dados is not None:
            jws_transacao = getattr(dados, "signedTransactionInfo", None)
            jws_renovacao = getattr(dados, "signedRenewalInfo", None)
            if jws_transacao:
                transacao = self.verificar_transacao(jws_transacao)
            if jws_renovacao:
                renovacao = self.verificar_renovacao(jws_renovacao)
            status = _bruto(dados, "status")
        return Notificacao(
            uuid=str(getattr(payload, "notificationUUID", "") or ""),
            tipo=str(_bruto(payload, "notificationType") or ""),
            subtipo=_bruto(payload, "subtype"),
            assinada_em=_data_ms(getattr(payload, "signedDate", None)),
            ambiente=self.ambiente,
            status=None if status is None else int(status),
            transacao=transacao,
            renovacao=renovacao,
        )


class ClienteApple:
    """`AppStoreServerAPIClient` de um ambiente (só `Get All Subscription Statuses`)."""

    def __init__(self, ambiente: str):
        bundle_id = _obrigatoria("APPLE_BUNDLE_ID")
        issuer_id = _obrigatoria("APPLE_ISSUER_ID")
        key_id = _obrigatoria("APPLE_KEY_ID")
        chave = _chave_privada()
        from appstoreserverlibrary.api_client import AppStoreServerAPIClient

        self.ambiente = ambiente
        self._verificador = obter_verificador(ambiente)
        self._cliente = AppStoreServerAPIClient(
            chave, key_id, issuer_id, bundle_id, _ambiente_biblioteca(ambiente)
        )

    def status(self, original_transaction_id: str) -> EstadoApple | None:
        """Estado atual da assinatura, ou `None` se a Apple não a conhece."""
        from appstoreserverlibrary.api_client import APIException

        try:
            resposta = self._cliente.get_all_subscription_statuses(original_transaction_id)
        except APIException as exc:
            http = getattr(exc, "http_status_code", None) or 0
            if http in (400, 404):
                return None
            raise AppleIndisponivel(f"HTTP {http}") from None
        except Exception as exc:  # rede, timeout
            raise AppleIndisponivel(type(exc).__name__) from None

        escolhido = None
        for grupo in getattr(resposta, "data", None) or []:
            for item in getattr(grupo, "lastTransactions", None) or []:
                if escolhido is None or str(getattr(item, "originalTransactionId", "")) == str(
                    original_transaction_id
                ):
                    escolhido = item
        if escolhido is None or not getattr(escolhido, "signedTransactionInfo", None):
            return None
        transacao = self._verificador.verificar_transacao(escolhido.signedTransactionInfo)
        renovacao = None
        if getattr(escolhido, "signedRenewalInfo", None):
            renovacao = self._verificador.verificar_renovacao(escolhido.signedRenewalInfo)
        return EstadoApple(
            status=int(_bruto(escolhido, "status")),
            transacao=transacao,
            renovacao=renovacao,
        )


# -------------------------------------------------------- fábricas (seam)


def obter_verificador(ambiente: str):
    """Verificador do ambiente. Os testes substituem esta função."""
    return VerificadorApple(ambiente)


def obter_cliente_apple(ambiente: str):
    """Cliente da App Store Server API do ambiente. Os testes substituem."""
    return ClienteApple(ambiente)


def ambientes_aceitos() -> tuple[str, ...]:
    return (PRODUCTION, SANDBOX) if aceita_sandbox() else (PRODUCTION,)


def _em_qualquer_ambiente(chamada):
    """Tenta Production; se o JWS for de outro ambiente, tenta Sandbox.

    Devolve `(resultado, ambiente)`. Sandbox recusado (`APPLE_ACEITA_SANDBOX
    =false`) vira `ComprovanteInvalido`.
    """
    ultimo: Exception | None = None
    for ambiente in ambientes_aceitos():
        try:
            return chamada(obter_verificador(ambiente)), ambiente
        except AmbienteErrado as exc:
            ultimo = exc
            continue
    raise ComprovanteInvalido("ambiente não aceito") from ultimo


def verificar_transacao(jws: str) -> tuple[Transacao, str]:
    return _em_qualquer_ambiente(lambda verificador: verificador.verificar_transacao(jws))


def verificar_notificacao(signed_payload: str) -> tuple[Notificacao, str]:
    return _em_qualquer_ambiente(
        lambda verificador: verificador.verificar_notificacao(signed_payload)
    )
