"""Rate limiting (slowapi).

A chave padrao da cota e o usuario: `chave_limite` devolve `user:<id>`
quando o `Authorization: Bearer` e um access token valido (assinatura e
validade conferidas por `auth_service.decodificar_access_token`, sem
consultar o banco); sem token ou com token invalido/expirado, cai no IP
real de `get_real_ip`.

Motivo: no celular varias pessoas saem pelo mesmo IP (CGNAT da operadora)
e dividiam a cota por IP; e o envio do app depois de dias sem internet
estoura tetos pensados para uso interativo.

Seguem contados por IP (`key_func=get_real_ip` no decorator), por serem a
porta de entrada sem login: `/auth/register`, `/auth/login`,
`/auth/refresh`, `/auth/logout`, `/health` e `/api/webhooks/apple`.
"""

import ipaddress
import os

from fastapi import Request
from slowapi import Limiter
from slowapi.util import get_remote_address

TRUST_PROXY = os.getenv("TRUST_PROXY", "false").lower() == "true"
TRUSTED_PROXY_IPS = tuple(
    ipaddress.ip_network(value.strip())
    for value in os.getenv("TRUSTED_PROXY_IPS", "127.0.0.1,::1").split(",")
    if value.strip()
)


def _ip_esta_em_proxy_confiavel(value: str) -> bool:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    return any(ip in network for network in TRUSTED_PROXY_IPS)


def get_real_ip(request: Request) -> str:
    remote_address = get_remote_address(request)
    if not TRUST_PROXY or not _ip_esta_em_proxy_confiavel(remote_address):
        return remote_address

    forwarded = request.headers.get("X-Forwarded-For")
    if not forwarded:
        return remote_address

    candidates = []
    for value in forwarded.split(","):
        try:
            candidates.append(str(ipaddress.ip_address(value.strip())))
        except ValueError:
            continue

    for candidate in reversed(candidates):
        if not _ip_esta_em_proxy_confiavel(candidate):
            return candidate
    return candidates[0] if candidates else remote_address


def chave_limite(request: Request) -> str:
    """`user:<id>` com Bearer valido; sem token ou invalido, o IP real."""
    authorization = request.headers.get("Authorization", "")
    if authorization.startswith("Bearer "):
        # O mesmo modulo que `dependencies.get_current_user` usa para validar:
        # `from services import auth_service` aqui pode achar outra copia se o
        # modulo foi reimportado em teste.
        from dependencies import auth_service

        dados = auth_service.decodificar_access_token(authorization[7:])
        if dados:
            return f"user:{dados[0]}"
    return get_real_ip(request)


limiter = Limiter(key_func=chave_limite)
