from fastapi import Header, HTTPException, Depends
from sqlalchemy.orm import Session
from database import get_db
from repositories import auth_repository
from services import assinatura_service, auth_service


def get_current_user(
    db: Session = Depends(get_db),
    authorization: str = Header(None),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Token nao fornecido")

    token = authorization.replace("Bearer ", "")
    dados = auth_service.decodificar_access_token(token)

    if not dados:
        raise HTTPException(status_code=401, detail="Token invalido ou expirado")

    user_id, session_id = dados
    # Token com "sid" so vale enquanto a sessao tiver refresh token ativo
    # (logout e reuso de refresh token derrubam na hora). Token sem "sid" foi
    # emitido antes dessa regra e segue aceito ate expirar.
    if session_id is not None and not auth_repository.sessao_ativa(
        db, session_id, user_id
    ):
        raise HTTPException(status_code=401, detail="Token invalido ou expirado")

    usuario = auth_repository.buscar_por_id(db, user_id)
    if not usuario:
        raise HTTPException(status_code=401, detail="Usuario nao encontrado")

    return usuario


def get_current_user_id(usuario = Depends(get_current_user)) -> str:
    return usuario.id


def exigir_assinatura(
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> None:
    """Bloqueia a rota sem assinatura (`docs/publicacao.md` §1.4).

    Só vai em criar ciclo, ler comprovante com IA, ler fatura e exportar.
    Com `BILLING_ENFORCEMENT` desligado (padrão), nunca bloqueia.
    """
    if not assinatura_service.tem_acesso(db, user_id):
        raise assinatura_service.AssinaturaNecessaria()
