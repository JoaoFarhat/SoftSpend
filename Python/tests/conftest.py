import importlib
import sys

import pytest


@pytest.fixture
def importar_main(monkeypatch):
    """Reimporta `main` com OPEN_FINANCE_ENABLED ligada/desligada.

    O registro das rotas do Pluggy é decidido na importação do módulo,
    então `main` precisa ser reimportado quando a flag muda de valor.
    Ao final do teste, `sys.modules["main"]` volta ao estado anterior.
    """
    main_anterior = sys.modules.pop("main", None)

    def _importar(habilitado: bool):
        if habilitado:
            monkeypatch.setenv("OPEN_FINANCE_ENABLED", "true")
        else:
            monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
        sys.modules.pop("main", None)
        return importlib.import_module("main")

    yield _importar

    sys.modules.pop("main", None)
    if main_anterior is not None:
        sys.modules["main"] = main_anterior
