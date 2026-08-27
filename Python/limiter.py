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

limiter = Limiter(key_func=get_real_ip)
