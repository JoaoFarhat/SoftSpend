import logging

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool

from dependencies import get_current_user_id
from dtos.fatura import FaturaLida
from limiter import limiter
from services import fatura_arquivo_service, fatura_ia_service
from services.fatura_arquivo_service import ErroFatura

logger = logging.getLogger(__name__)
router = APIRouter(tags=["faturas"])


@router.post("/api/faturas/ler", response_model=FaturaLida)
@limiter.limit("5/minute")
async def ler_fatura(
    request: Request,
    arquivo: UploadFile = File(...),
    senha: str | None = Form(default=None),
    user_id: str = Depends(get_current_user_id),
) -> FaturaLida:
    """Lê a fatura (PDF com senha opcional, OFX ou CSV) e devolve a prévia.

    Só leitura: nada é gravado no banco nem no S3 e o arquivo original é
    descartado ao fim da requisição. A senha do PDF nunca é logada.
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

        return fatura_arquivo_service.montar_fatura_lida(bruta)
    except ErroFatura as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail)
    except HTTPException:
        raise
    except Exception:
        logger.exception("Falha ao ler fatura")
        raise HTTPException(status_code=500, detail="Erro ao processar a fatura")
