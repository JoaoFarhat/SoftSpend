import logging
import os
import re
import time
import uuid

from fastapi import Request, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, RedirectResponse
from starlette.middleware.base import BaseHTTPMiddleware

from limiter import get_real_ip
from logging_config import request_id_var

logger = logging.getLogger(__name__)
REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,128}$")

HSTS_MAX_AGE = int(os.getenv("HSTS_MAX_AGE", "31536000"))


class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID")
        if not request_id or not REQUEST_ID_PATTERN.fullmatch(request_id):
            request_id = str(uuid.uuid4())
        request.state.request_id = request_id
        token = request_id_var.set(request_id)

        try:
            response = await call_next(request)
            response.headers["X-Request-ID"] = request_id
            return response
        finally:
            request_id_var.reset(token)


class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start = time.perf_counter()

        logger.info(
            "Request started",
            extra={
                "method": request.method,
                "path": request.url.path,
                "ip": self._get_client_ip(request),
                "user_agent": request.headers.get("User-Agent", "-"),
            },
        )

        try:
            response = await call_next(request)
        except Exception:
            duration_ms = round((time.perf_counter() - start) * 1000, 2)
            logger.error(
                "Request failed",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status_code": 500,
                    "duration_ms": duration_ms,
                    "ip": self._get_client_ip(request),
                    "user_agent": request.headers.get("User-Agent", "-"),
                },
            )
            raise

        duration_ms = round((time.perf_counter() - start) * 1000, 2)
        logger.info(
            "Request finished",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": duration_ms,
                "ip": self._get_client_ip(request),
                "user_agent": request.headers.get("User-Agent", "-"),
            },
        )

        return response

    def _get_client_ip(self, request: Request) -> str:
        return get_real_ip(request)


class EnforceHTTPSMiddleware(BaseHTTPMiddleware):
    """Redireciona HTTP para HTTPS quando o proxy informa X-Forwarded-Proto.

    Em producao o nginx/ALB termina TLS e repassa o protocolo real no header
    X-Forwarded-Proto. Requisicoes diretas (ex: health check local) nao tem esse
    header, entao nao sao redirecionadas — isso permite health checks HTTP
    internos sem quebrar o CI/deploy.
    """

    async def dispatch(self, request: Request, call_next):
        forwarded_proto = request.headers.get("X-Forwarded-Proto")
        is_https = request.url.scheme == "https" or forwarded_proto == "https"

        if not is_https and forwarded_proto == "http":
            https_url = str(request.url.replace(scheme="https"))
            response = RedirectResponse(url=https_url, status_code=308)
            response.headers["Strict-Transport-Security"] = (
                f"max-age={HSTS_MAX_AGE}; includeSubDomains"
            )
            return response

        response = await call_next(request)

        if is_https:
            response.headers["Strict-Transport-Security"] = (
                f"max-age={HSTS_MAX_AGE}; includeSubDomains"
            )

        return response


def get_request_id(request: Request) -> str:
    return getattr(request.state, "request_id", "-")


def build_error_response(request: Request, status_code: int, message: str):
    return JSONResponse(
        status_code=status_code,
        content={
            "error": message,
            "request_id": get_request_id(request),
        },
    )


def setup_exception_handlers(app):
    @app.exception_handler(HTTPException)
    async def http_exception_handler(request: Request, exc: HTTPException):
        if exc.status_code >= 500:
            logger.error(
                exc.detail,
                extra={
                    "status_code": exc.status_code,
                    "path": request.url.path,
                },
            )
        else:
            logger.warning(
                exc.detail,
                extra={
                    "status_code": exc.status_code,
                    "path": request.url.path,
                },
            )
        return build_error_response(request, exc.status_code, exc.detail)

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(request: Request, exc: RequestValidationError):
        logger.warning(
            "Validation error",
            extra={
                "path": request.url.path,
                "errors": exc.errors(),
            },
        )
        return build_error_response(request, 422, "Dados de entrada invalidos")

    @app.exception_handler(Exception)
    async def global_exception_handler(request: Request, exc: Exception):
        logger.exception(
            "Unhandled exception",
            extra={
                "path": request.url.path,
            },
        )
        return build_error_response(request, 500, "Erro interno no servidor")
