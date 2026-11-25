import json
import logging
import sys
from contextvars import ContextVar
from datetime import datetime, timezone

request_id_var: ContextVar[str] = ContextVar("request_id", default="-")

# Atributos que todo LogRecord ja tem (`makeLogRecord({})`), mais os que o
# Formatter cria ao formatar (`message`, `asctime`) e o `request_id` gravado
# pelo RequestContextFilter: nenhum deles entra como campo extra — o
# `extra={...}` do logger.info vira atributo direto do record, e e isso que
# queremos copiar.
_ATRIBUTOS_PADRAO = frozenset(logging.makeLogRecord({}).__dict__) | {
    "message",
    "asctime",
    "request_id",
}


class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        if record.exc_info:
            log_data["exception"] = self.formatException(record.exc_info)
        for chave, valor in record.__dict__.items():
            if chave not in _ATRIBUTOS_PADRAO:
                log_data.setdefault(chave, valor)
        return json.dumps(log_data, default=str)


class RequestContextFilter(logging.Filter):
    def filter(self, record):
        record.request_id = request_id_var.get()
        return True


def setup_logging(level: int = logging.INFO):
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    handler.addFilter(RequestContextFilter())

    root = logging.getLogger()
    root.setLevel(level)
    root.handlers = []
    root.addHandler(handler)

    for name in ["uvicorn", "uvicorn.access", "uvicorn.error", "fastapi"]:
        logger = logging.getLogger(name)
        logger.handlers = []
        logger.addHandler(handler)
        logger.propagate = False
