"""Conta de demonstração (`docs/publicacao.md` §2): `ACESSO_LIBERADO_USUARIOS`
e `scripts/criar_conta_demo.py`.

Mesmo padrão de `test_assinatura.py`: SQLite em `tmp_path` e
`dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib
import sys
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from scripts import criar_conta_demo

USER_A = "user-a"
USER_B = "user-b"
SENHA_DEMO = "SenhaForte1!"

# PNG mínimo e OFX mínimo: iguais aos de test_assinatura.py.
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + b"\x00" * 32
OFX = (
    "OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\n<OFX>"
    "<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS>"
    "<DTSERVER>20261020<LANGUAGE>POR<FI><ORG>Banco Teste</FI></SONRS>"
    "</SIGNONMSGSRSV1><CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL"
    "<CCACCTFROM><ACCTID>1234</CCACCTFROM><BANKTRANLIST>"
    "<DTSTART>20260901000000<DTEND>20261007000000"
    "<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261002000000<TRNAMT>-10.00"
    "<FITID>t0<MEMO>PADARIA</STMTTRN>"
    "</BANKTRANLIST><LEDGERBAL><BALAMT>10.00<DTASOF>20261020000000</LEDGERBAL>"
    "</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>"
).encode()


class _Ambiente:
    def __init__(self, app, session):
        self.app = app
        self.session = session

    def como(self, user_id: str) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app)


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    import models
    from services import ocr_service

    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    monkeypatch.delenv("ACESSO_LIBERADO_USUARIOS", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)
    monkeypatch.setattr(
        ocr_service,
        "extrair_gasto_da_imagem",
        lambda conteudo: {"titulo": "Padaria", "valor": "10.00", "categoria": "ALIMENTACAO"},
    )

    engine = create_engine(f"sqlite:///{tmp_path}/conta_demo.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(id=USER_A, nome="A", username="a", email="a@e.com", senha_hash="h"),
            models.User(id=USER_B, nome="B", username="b", email="b@e.com", senha_hash="h"),
        ]
    )
    session.commit()

    def override_db():
        yield session
        session.commit()

    app.dependency_overrides[get_db] = override_db
    try:
        yield _Ambiente(app, session)
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


def _ciclo(client, client_id="ciclo-1"):
    return client.post(
        "/ciclos",
        json={
            "client_id": client_id,
            "valor_total": "700.00",
            "periodo": "01/11/2026 a 07/11/2026",
            "diaria": "100.00",
            "titulo": "Semana",
        },
    )


def _quatro_rotas(client, ciclo_id):
    """As 4 rotas bloqueadas: (nome, resposta)."""
    return [
        ("POST /ciclos", _ciclo(client, "ciclo-novo")),
        (
            "POST /gastos/extrair",
            client.post("/gastos/extrair", files={"imagem": ("nota.png", PNG, "image/png")}),
        ),
        (
            "POST /api/faturas/ler",
            client.post(
                "/api/faturas/ler",
                files={"arquivo": ("fatura.ofx", OFX, "application/ofx")},
            ),
        ),
        (
            "GET /ciclos/{id}/export",
            client.get(f"/ciclos/{ciclo_id}/export", params={"formato": "csv"}),
        ),
    ]


def _ciclo_existente(ambiente, user_id=USER_A) -> int:
    import models

    ciclo = models.Ciclo(
        id_usuario=user_id,
        client_id=f"semente-{user_id}",
        valor_total=700,
        gasto_total=0,
        periodo="01/11/2026 a 07/11/2026",
        diaria=100,
        titulo="Semana",
    )
    ambiente.session.add(ciclo)
    ambiente.session.commit()
    return ciclo.id


# ------------------------------------------------------ ACESSO_LIBERADO_USUARIOS


def test_id_liberado_passa_nas_4_rotas(ambiente, monkeypatch):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    monkeypatch.setenv("ACESSO_LIBERADO_USUARIOS", USER_A)
    ciclo_id = _ciclo_existente(ambiente)
    client = ambiente.como(USER_A)
    for nome, resposta in _quatro_rotas(client, ciclo_id):
        assert resposta.status_code == 200, (nome, resposta.text)


def test_id_liberado_numa_lista_com_espacos(ambiente, monkeypatch):
    """Vários ids separados por vírgula, com espaços e outra forma de UUID."""
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    monkeypatch.setenv(
        "ACESSO_LIBERADO_USUARIOS", f"  outro-id , {USER_A.upper()} ,"
    )
    assert _ciclo(ambiente.como(USER_A)).status_code == 200


def test_outro_id_continua_com_403(ambiente, monkeypatch):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    monkeypatch.setenv("ACESSO_LIBERADO_USUARIOS", USER_A)
    ciclo_id = _ciclo_existente(ambiente, USER_B)
    for nome, resposta in _quatro_rotas(ambiente.como(USER_B), ciclo_id):
        assert resposta.status_code == 403, (nome, resposta.text)
        assert resposta.json()["detail"] == "subscription_required", nome


@pytest.mark.parametrize("valor", [None, "", "   "])
def test_variavel_vazia_nao_libera_ninguem(ambiente, monkeypatch, valor):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    if valor is None:
        monkeypatch.delenv("ACESSO_LIBERADO_USUARIOS", raising=False)
    else:
        monkeypatch.setenv("ACESSO_LIBERADO_USUARIOS", valor)
    client = ambiente.como(USER_A)
    assert _ciclo(client, "c-bloqueado").status_code == 403


def test_liberacao_lida_a_cada_chamada(ambiente, monkeypatch):
    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    client = ambiente.como(USER_A)
    monkeypatch.setenv("ACESSO_LIBERADO_USUARIOS", USER_A)
    assert _ciclo(client, "c-1").status_code == 200
    monkeypatch.delenv("ACESSO_LIBERADO_USUARIOS")
    assert _ciclo(client, "c-2").status_code == 403


def test_get_assinatura_tem_acesso_com_status_real(ambiente, monkeypatch):
    import models

    monkeypatch.setenv("BILLING_ENFORCEMENT", "on")
    monkeypatch.setenv("ACESSO_LIBERADO_USUARIOS", USER_A)
    corpo = ambiente.como(USER_A).get("/api/assinatura").json()
    assert corpo["tem_acesso"] is True
    # Sem compra, o status real é `none` — a liberação não finge assinatura.
    assert corpo["status"] == "none"
    linha = ambiente.session.query(models.Assinatura).filter_by(user_id=USER_A).one()
    assert linha.status == "none"
    assert linha.original_transaction_id is None


# ------------------------------------------------------- criar_conta_demo


def _rodar_script(ambiente, monkeypatch, *argv):
    import database

    monkeypatch.setattr(database, "SessionLocal", lambda: ambiente.session)
    monkeypatch.setenv("DEMO_SENHA", SENHA_DEMO)
    return criar_conta_demo.main(list(argv) or ["--email", "demo@softspend.com.br"])


def test_script_cria_conta_com_viagem_de_7_dias(ambiente, monkeypatch, capsys):
    import models
    from services import auth_service

    # Data fixa: o teste não pode falhar quando a execução cruza a meia-noite.
    hoje = date(2026, 11, 15)

    class _DataFixa(date):
        @classmethod
        def today(cls):
            return hoje

    monkeypatch.setattr(criar_conta_demo, "date", _DataFixa)

    assert _rodar_script(ambiente, monkeypatch) == 0
    saida = capsys.readouterr()

    usuario = ambiente.session.query(models.User).filter_by(
        email="demo@softspend.com.br"
    ).one()
    # O stdout é só o id, para ir direto a ACESSO_LIBERADO_USUARIOS.
    assert saida.out.strip() == usuario.id
    assert SENHA_DEMO not in saida.out and SENHA_DEMO not in saida.err

    # Mesmo hash do cadastro: a senha passa na verificação do login.
    assert auth_service._verificar_senha(SENHA_DEMO, usuario.senha_hash)

    ciclos = ambiente.session.query(models.Ciclo).filter_by(id_usuario=usuario.id).all()
    assert len(ciclos) == 1
    dias = sorted(ciclos[0].dias, key=lambda d: d.data)
    assert len(dias) == 7
    assert dias[-1].data.date() == hoje
    assert dias[0].data.date() == hoje - timedelta(days=6)

    total_gastos = 0
    for dia in dias:
        assert 2 <= len(dia.gastos) <= 4
        assert all(g.comprovante_key is None for g in dia.gastos)
        total_gastos += sum(g.valor for g in dia.gastos)
    assert ciclos[0].gasto_total == total_gastos

    categorias = {g.categoria for dia in dias for g in dia.gastos}
    assert len(categorias) >= 3


def test_script_segunda_execucao_nao_duplica(ambiente, monkeypatch, capsys):
    import models

    assert _rodar_script(ambiente, monkeypatch) == 0
    capsys.readouterr()

    assert _rodar_script(ambiente, monkeypatch) == 0
    saida = capsys.readouterr()
    assert saida.out.strip() == ""
    assert "já existe" in saida.err

    usuario = ambiente.session.query(models.User).filter_by(
        email="demo@softspend.com.br"
    ).one()
    assert ambiente.session.query(models.Ciclo).filter_by(
        id_usuario=usuario.id
    ).count() == 1


def test_script_sem_demo_senha_nao_cria(ambiente, monkeypatch, capsys):
    import database
    import models

    monkeypatch.setattr(database, "SessionLocal", lambda: ambiente.session)
    monkeypatch.delenv("DEMO_SENHA", raising=False)
    assert criar_conta_demo.main(["--email", "demo@softspend.com.br"]) == 2
    saida = capsys.readouterr()
    assert "DEMO_SENHA" in saida.err
    assert ambiente.session.query(models.User).filter_by(
        email="demo@softspend.com.br"
    ).count() == 0
