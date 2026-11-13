import logging

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from sqlalchemy.orm import Session

from database import get_db
from dependencies import exigir_assinatura, get_current_user_id
from dtos.fatura import FaturaLida
from dtos.open_finance import (
    CreditCardBillDetailResponse,
    CreditCardBillResponse,
    ExpenseTransactionMatchResponse,
)
from limiter import limiter
from repositories import open_finance_repository
from services import (
    fatura_arquivo_service,
    fatura_ia_service,
    fatura_service,
    open_finance_reconciliation_service,
)
from services.fatura_arquivo_service import ErroFatura

logger = logging.getLogger(__name__)
router = APIRouter(tags=["faturas"])


@router.post(
    "/api/faturas/ler",
    response_model=FaturaLida,
    dependencies=[Depends(exigir_assinatura)],
)
@limiter.limit("5/minute")
async def ler_fatura(
    request: Request,
    arquivo: UploadFile = File(...),
    senha: str | None = Form(default=None),
    ciclo_id: int | None = Form(default=None),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FaturaLida:
    """Lê a fatura (PDF com senha opcional, OFX ou CSV) e devolve a prévia.

    Só leitura: nada é gravado no banco nem no S3 e o arquivo original é
    descartado ao fim da requisição. A senha do PDF nunca é logada. Com
    `ciclo_id`, as compras dentro das datas da viagem ganham
    `dentro_da_viagem`/`dia_id` e a prévia do vínculo (`match`).
    """
    try:
        tipo, conteudo = await fatura_arquivo_service.ler_upload(arquivo)

        if tipo == "pdf":
            pdf_aberto = await run_in_threadpool(
                fatura_arquivo_service.desproteger_pdf, conteudo, senha
            )
            bruta = await run_in_threadpool(fatura_ia_service.ler_fatura_pdf, pdf_aberto)
        elif tipo == "ofx":
            bruta = fatura_arquivo_service.ler_ofx(conteudo)
        else:
            bruta = fatura_arquivo_service.ler_csv(conteudo)

        lida = fatura_arquivo_service.montar_fatura_lida(bruta)
        if ciclo_id is not None:
            await run_in_threadpool(
                fatura_service.marcar_previa, db, user_id, ciclo_id, lida
            )
        return lida
    except ErroFatura as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail)
    except HTTPException:
        raise
    except Exception:
        logger.exception("Falha ao ler fatura")
        raise HTTPException(status_code=500, detail="Erro ao processar a fatura")


@router.post("/api/faturas", response_model=CreditCardBillDetailResponse)
@limiter.limit("10/minute")
def gravar_fatura(
    request: Request,
    lida: FaturaLida,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """Grava a fatura e as compras confirmadas (idempotente) e concilia.

    O corpo é a `FaturaLida` da prévia já sem as compras que a pessoa tirou
    da conferência; o `transaction_id` determinístico impede duplicatas.
    """
    try:
        fatura = fatura_service.gravar_fatura(db, user_id, lida)
    except ErroFatura as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail)
    open_finance_reconciliation_service.conciliar_usuario(db, user_id)
    fatura.transacoes = open_finance_repository.listar_transacoes_fatura(
        db, user_id, fatura.id
    )
    return fatura


@router.post(
    "/api/faturas/{fatura_id}/conciliar",
    response_model=CreditCardBillDetailResponse,
)
@limiter.limit("10/minute")
def conciliar_fatura(
    request: Request,
    fatura_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """Roda a conciliação de novo (o app chama depois de sincronizar os
    gastos criados na conferência)."""
    fatura = fatura_service.buscar_importada(db, user_id, fatura_id)
    if fatura is None:
        raise HTTPException(status_code=404, detail="Fatura não encontrada")
    open_finance_reconciliation_service.conciliar_usuario(db, user_id)
    fatura.transacoes = open_finance_repository.listar_transacoes_fatura(
        db, user_id, fatura.id
    )
    return fatura


@router.get("/api/faturas", response_model=list[CreditCardBillResponse])
@limiter.limit("60/minute")
def listar_faturas_importadas(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    return fatura_service.listar_importadas(db, user_id)


@router.get(
    "/api/faturas/{fatura_id}", response_model=CreditCardBillDetailResponse
)
@limiter.limit("60/minute")
def detalhar_fatura_importada(
    request: Request,
    fatura_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    fatura = fatura_service.buscar_importada(db, user_id, fatura_id)
    if fatura is None:
        raise HTTPException(status_code=404, detail="Fatura não encontrada")
    fatura.transacoes = open_finance_repository.listar_transacoes_fatura(
        db, user_id, fatura.id
    )
    return fatura


@router.delete("/api/faturas/{fatura_id}", response_model=CreditCardBillResponse)
@limiter.limit("30/minute")
def apagar_fatura_importada(
    request: Request,
    fatura_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """Apaga a fatura importada, suas compras e vínculos; os gastos ficam."""
    fatura = fatura_service.buscar_importada(db, user_id, fatura_id)
    if fatura is None:
        raise HTTPException(status_code=404, detail="Fatura não encontrada")
    resposta = CreditCardBillResponse.model_validate(fatura)
    fatura_service.apagar_importada(db, fatura)
    return resposta


@router.post(
    "/api/faturas/matches/{match_id}/confirm",
    response_model=ExpenseTransactionMatchResponse,
)
@limiter.limit("30/minute")
def confirmar_match(
    request: Request,
    match_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    match = open_finance_repository.buscar_match(db, user_id, match_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match não encontrado")
    return open_finance_repository.confirmar_match(db, match)


@router.delete(
    "/api/faturas/matches/{match_id}",
    response_model=ExpenseTransactionMatchResponse,
)
@limiter.limit("30/minute")
def remover_match(
    request: Request,
    match_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    match = open_finance_repository.buscar_match(db, user_id, match_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match não encontrado")
    response = ExpenseTransactionMatchResponse.model_validate(match)
    open_finance_repository.remover_match(db, match)
    return response
