from fastapi import FastAPI, Depends
from sqlalchemy.orm import Session
from database import *
from fastapi.middleware.cors import CORSMiddleware
from controllers.ciclo_controller import router as ciclo_router
from controllers.gasto_controller import router as gasto_router
from controllers.auth_controller import router as auth_router
from slowapi import _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from limiter import limiter

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ciclo_router)
app.include_router(gasto_router)
app.include_router(auth_router)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

Base.metadata.create_all(bind=engine)

