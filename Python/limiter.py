from slowapi import Limiter
from slowapi.util import get_remote_address
from fastapi import Request
import os

TRUST_PROXY = os.getenv("TRUST_PROXY", "false").lower() == "true"

def get_real_ip(request: Request) -> str:
    if TRUST_PROXY:
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return get_remote_address(request)

limiter = Limiter(key_func=get_real_ip)