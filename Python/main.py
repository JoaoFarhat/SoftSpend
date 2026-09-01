import asyncio
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from sqlalchemy import text
from database import get_db
from controllers.ciclo_controller import router as ciclo_router
from controllers.dia_controller import router as dia_router
from controllers.gasto_controller import router as gasto_router
from controllers.auth_controller import router as auth_router
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware
from limiter import limiter
from logging_config import setup_logging
from middlewares import (
    RequestIDMiddleware,
    LoggingMiddleware,
    EnforceHTTPSMiddleware,
    setup_exception_handlers,
)
from services import ocr_service
from services import comprovante_cleanup

setup_logging()
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    tarefa = asyncio.create_task(asyncio.to_thread(ocr_service.aquecer))
    yield
    tarefa.cancel()


DOCS_ENABLED = os.getenv("DOCS_ENABLED", "false").lower() == "true"

app = FastAPI(
    lifespan=lifespan,
    docs_url="/docs" if DOCS_ENABLED else None,
    redoc_url="/redoc" if DOCS_ENABLED else None,
    openapi_url="/openapi.json" if DOCS_ENABLED else None,
)

ALLOWED_ORIGINS_STR = os.getenv("ALLOWED_ORIGINS", "https://softspend.com.br")
ALLOWED_ORIGINS = [o.strip() for o in ALLOWED_ORIGINS_STR.split(",") if o.strip()]

app.add_middleware(LoggingMiddleware)
app.add_middleware(EnforceHTTPSMiddleware)
app.add_middleware(RequestIDMiddleware)
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
setup_exception_handlers(app)


@app.get("/health", include_in_schema=False)
def health_check(db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
        return JSONResponse(content={"status": "ok"})
    except Exception as exc:
        logger.error("Health check falhou: %s", exc)
        raise HTTPException(status_code=503, detail="Database unavailable")
