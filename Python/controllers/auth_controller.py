from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from database import get_db
from dependencies import get_current_user_id
from dtos.auth import (
    RegisterRequest,
    LoginRequest,
    RefreshRequest,
    LogoutRequest,
    AuthResponse,
    EsqueciSenhaRequest,
    EsqueciSenhaResponse,
    RedefinirSenhaRequest,
)
from services import auth_service, email_service, redefinicao_senha_service
from limiter import limiter, get_real_ip

router = APIRouter(prefix="/auth", tags=["auth"])


def _montar_auth_response(usuario, access_token: str, refresh_token: str) -> AuthResponse:
    expires_in = auth_service.ACCESS_TOKEN_EXPIRE_MINUTES * 60
    return AuthResponse(
        id=usuario.id,
        nome=usuario.nome,
        username=usuario.username,
        email=usuario.email,
        access_token=access_token,
        refresh_token=refresh_token,
        token_type="bearer",
        expires_in=expires_in,
    )


@router.post("/register", response_model=AuthResponse)
@limiter.limit("3/minute", key_func=get_real_ip)
def register(request: Request, dados: RegisterRequest, db: Session = Depends(get_db)):
    try:
        usuario = auth_service.registrar(db, dados)
        access_token, refresh_token = auth_service.iniciar_sessao(db, usuario.id)
        return _montar_auth_response(usuario, access_token, refresh_token)
    except auth_service.EmailJaCadastrado:
        raise HTTPException(status_code=409, detail=auth_service.ERRO_EMAIL_JA_CADASTRADO)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/login", response_model=AuthResponse)
@limiter.limit("5/minute", key_func=get_real_ip)
def login(request: Request, dados: LoginRequest, db: Session = Depends(get_db)):
    try:
        usuario, access_token, refresh_token = auth_service.login(db, dados)
        return _montar_auth_response(usuario, access_token, refresh_token)
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


@router.post("/refresh", response_model=AuthResponse)
@limiter.limit("60/minute", key_func=get_real_ip)
def refresh(
    request: Request, dados: RefreshRequest, db: Session = Depends(get_db)
):
    try:
        usuario, access_token, refresh_token = auth_service.refresh_access_token(
            db, dados.refresh_token
        )
        return _montar_auth_response(usuario, access_token, refresh_token)
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


@router.post("/logout", status_code=204)
@limiter.limit("30/minute", key_func=get_real_ip)
def logout(request: Request, dados: LogoutRequest, db: Session = Depends(get_db)):
    auth_service.logout(db, dados.refresh_token)
    return None


@router.delete("/conta", status_code=204)
@limiter.limit("10/minute")
def excluir_conta(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    auth_service.excluir_conta(db, user_id)
    return None


ERRO_EMAIL_INDISPONIVEL = "email_unavailable"


@router.post("/senha/esqueci", status_code=202, response_model=EsqueciSenhaResponse)
@limiter.limit("5/minute", key_func=get_real_ip)
def esqueci_senha(
    request: Request,
    dados: EsqueciSenhaRequest,
    background: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """Manda um codigo de 6 digitos se houver conta. A resposta e a mesma com ou
    sem conta (nao revela quem e cliente); o e-mail sai em background."""
    if not email_service.esta_configurado():
        raise HTTPException(status_code=503, detail=ERRO_EMAIL_INDISPONIVEL)
    envio = redefinicao_senha_service.pedir_codigo(db, dados.email)
    if envio is not None:
        background.add_task(
            email_service.enviar_codigo_redefinicao,
            envio.email,
            envio.nome,
            envio.codigo,
            redefinicao_senha_service.VALIDADE_MINUTOS,
        )
    return EsqueciSenhaResponse(
        expires_in_seconds=redefinicao_senha_service.VALIDADE_MINUTOS * 60,
        resend_after_seconds=redefinicao_senha_service.REENVIO_SEGUNDOS,
    )


@router.post("/senha/redefinir", status_code=204)
@limiter.limit("5/minute", key_func=get_real_ip)
def redefinir_senha(request: Request, dados: RedefinirSenhaRequest, db: Session = Depends(get_db)):
    """Troca a senha com o codigo e encerra todas as sessoes. Qualquer falha do
    codigo (errado, expirado, sem pedido, sem conta) e o mesmo 400."""
    try:
        redefinicao_senha_service.redefinir(db, dados.email, dados.codigo, dados.nova_senha)
    except redefinicao_senha_service.CodigoInvalido:
        raise HTTPException(
            status_code=400, detail=redefinicao_senha_service.ERRO_CODIGO_INVALIDO
        )
    return None
