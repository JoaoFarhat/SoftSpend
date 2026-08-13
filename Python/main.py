import asyncio
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from controllers.ciclo_controller import router as ciclo_router
from controllers.dia_controller import router as dia_router
from controllers.gasto_controller import router as gasto_router
from controllers.auth_controller import router as auth_router
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware
from limiter import limiter
from services import ocr_service
from services import comprovante_cleanup

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    tarefa = asyncio.create_task(asyncio.to_thread(ocr_service.aquecer))
    yield
    tarefa.cancel()


app = FastAPI(lifespan=lifespan)

ALLOWED_ORIGINS_STR = os.getenv("ALLOWED_ORIGINS", "https://softspend.com.br")
ALLOWED_ORIGINS = [o.strip() for o in ALLOWED_ORIGINS_STR.split(",") if o.strip()]


@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response


app.add_middleware(SlowAPIMiddleware)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ciclo_router)
app.include_router(dia_router)
app.include_router(gasto_router)
app.include_router(auth_router)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)


@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception):
    logging.exception("Erro interno nao tratado: %s", exc)
    return JSONResponse(
        status_code=500,
        content={"detail": "Erro interno no servidor"},
    )
