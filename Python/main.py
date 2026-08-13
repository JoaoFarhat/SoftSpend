import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Depends
from sqlalchemy.orm import Session
from database import *
from fastapi.middleware.cors import CORSMiddleware
from controllers.ciclo_controller import router as ciclo_router
from controllers.dia_controller import router as dia_router
from controllers.gasto_controller import router as gasto_router
from controllers.auth_controller import router as auth_router
from slowapi import _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from limiter import limiter
from services import ocr_service

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    tarefa = asyncio.create_task(asyncio.to_thread(ocr_service.aquecer))
    yield
    tarefa.cancel()


app = FastAPI(lifespan=lifespan)

ALLOWED_ORIGINS = [
    "https://softspend.com.br"  
]

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

Base.metadata.create_all(bind=engine)

