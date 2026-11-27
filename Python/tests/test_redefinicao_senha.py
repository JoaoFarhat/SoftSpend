"""Esqueci minha senha: POST /auth/senha/esqueci e /auth/senha/redefinir.

Camada de auth real com SQLite em `tmp_path` (como test_email_espacos.py). O
envio de e-mail e trocado por uma lista (`enviados`), sem SES.
"""

import importlib
import sys
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

SENHA = "Senha123!"
NOVA = "Nova#Senha9"
EMAIL = "joao@exemplo.com"


def _app(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    return importlib.import_module("main").app


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    from services import email_service

    app = _app(monkeypatch)
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)
    monkeypatch.setenv("EMAIL_REMETENTE", "SoftSpend <nao-responda@softspend.com.br>")

    enviados = []
    monkeypatch.setattr(
        email_service,
        "enviar_codigo_redefinicao",
        lambda para, nome, codigo, minutos: enviados.append((para, nome, codigo, minutos)),
    )

    engine = create_engine(f"sqlite:///{tmp_path}/redefinicao.db")
    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine)

    def override_db():
        db = SessionLocal()
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_db
    try:
        with TestClient(app) as c:
            yield c, SessionLocal, enviados
    finally:
        app.dependency_overrides.clear()
        engine.dispose()


def _cadastrar(client, email=EMAIL):
    resp = client.post(
        "/auth/register",
        json={"nome": "João Victor", "username": "joao_teste", "email": email, "senha": SENHA},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _pedir(client, email=EMAIL):
    return client.post("/auth/senha/esqueci", json={"email": email})


def _redefinir(client, codigo, email=EMAIL, senha=NOVA):
    return client.post(
        "/auth/senha/redefinir",
        json={"email": email, "codigo": codigo, "nova_senha": senha},
    )


def _login(client, senha, email=EMAIL):
    return client.post("/auth/login", json={"email": email, "senha": senha})


def test_pedido_responde_igual_com_e_sem_conta(ambiente):
    client, _, enviados = ambiente
    _cadastrar(client)

    com_conta = _pedir(client)
    sem_conta = _pedir(client, "ninguem@exemplo.com")

    assert com_conta.status_code == sem_conta.status_code == 202
    assert com_conta.json() == sem_conta.json() == {
        "expires_in_seconds": 900,
        "resend_after_seconds": 60,
    }
    # So a conta que existe recebe e-mail.
    assert [e[0] for e in enviados] == [EMAIL]
    assert enviados[0][1] == "João Victor"
    assert len(enviados[0][2]) == 6 and enviados[0][2].isdigit()
    assert enviados[0][3] == 15


def test_codigo_certo_troca_a_senha_e_derruba_as_sessoes(ambiente):
    client, _, enviados = ambiente
    sessao = _cadastrar(client)
    _pedir(client)
    codigo = enviados[0][2]

    assert _redefinir(client, codigo).status_code == 204

    assert _login(client, NOVA).status_code == 200
    assert _login(client, SENHA).status_code == 401
    # O refresh token de antes da troca nao vale mais.
    refresh = client.post("/auth/refresh", json={"refresh_token": sessao["refresh_token"]})
    assert refresh.status_code == 401
    # O codigo e de uso unico.
    assert _redefinir(client, codigo, senha="Outra#Senha8").status_code == 400


def test_codigo_errado_e_sem_pedido_dao_o_mesmo_erro(ambiente):
    client, _, enviados = ambiente
    _cadastrar(client)

    sem_pedido = _redefinir(client, "123456")
    sem_conta = _redefinir(client, "123456", email="ninguem@exemplo.com")
    _pedir(client)
    codigo = enviados[0][2]
    errado = _redefinir(client, "000000" if codigo != "000000" else "111111")

    for resp in (sem_pedido, sem_conta, errado):
        assert resp.status_code == 400, resp.text
        assert "invalid_reset_code" in resp.text
    assert _login(client, SENHA).status_code == 200


def test_cinco_tentativas_erradas_invalidam_o_codigo(ambiente):
    client, _, enviados = ambiente
    _cadastrar(client)
    _pedir(client)
    codigo = enviados[0][2]
    errado = "000000" if codigo != "000000" else "111111"

    for _ in range(5):
        assert _redefinir(client, errado).status_code == 400

    # Esgotado: nem o certo entra mais, e a senha antiga continua.
    assert _redefinir(client, codigo).status_code == 400
    assert _login(client, SENHA).status_code == 200


def test_codigo_expirado_nao_vale(ambiente):
    client, SessionLocal, enviados = ambiente
    _cadastrar(client)
    _pedir(client)
    codigo = enviados[0][2]

    import models

    with SessionLocal() as db:
        registro = db.query(models.CodigoRedefinicaoSenha).one()
        registro.expires_at = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(seconds=1)
        db.commit()

    assert _redefinir(client, codigo).status_code == 400
    with SessionLocal() as db:
        assert db.query(models.CodigoRedefinicaoSenha).count() == 0


def test_pedir_de_novo_antes_de_um_minuto_nao_gera_outro_codigo(ambiente):
    client, SessionLocal, enviados = ambiente
    _cadastrar(client)

    assert _pedir(client).status_code == 202
    assert _pedir(client).status_code == 202
    assert len(enviados) == 1

    # Passado o minuto, sai um codigo novo e o anterior deixa de valer.
    import models

    with SessionLocal() as db:
        registro = db.query(models.CodigoRedefinicaoSenha).one()
        registro.created_at = registro.created_at - timedelta(seconds=61)
        db.commit()

    assert _pedir(client).status_code == 202
    assert len(enviados) == 2
    antigo, novo = enviados[0][2], enviados[1][2]
    if antigo != novo:
        assert _redefinir(client, antigo).status_code == 400
    assert _redefinir(client, novo).status_code == 204


def test_senha_nova_fraca_ou_codigo_mal_formado_dao_422(ambiente):
    client, _, enviados = ambiente
    _cadastrar(client)
    _pedir(client)
    codigo = enviados[0][2]

    assert _redefinir(client, codigo, senha="fraca").status_code == 422
    assert _redefinir(client, "12a456").status_code == 422
    assert _redefinir(client, "12345").status_code == 422
    # A recusa por formato nao gasta tentativa: o codigo certo ainda entra.
    assert _redefinir(client, codigo).status_code == 204


def test_sem_remetente_configurado_responde_503(ambiente, monkeypatch):
    client, _, enviados = ambiente
    _cadastrar(client)
    monkeypatch.delenv("EMAIL_REMETENTE")

    resp = _pedir(client)
    assert resp.status_code == 503
    assert "email_unavailable" in resp.text
    assert enviados == []


def test_corpo_do_email_tem_o_codigo_e_a_validade():
    from services import email_service

    texto, html = email_service._corpo_codigo("João Victor", "042917", 15)
    assert "042917" in texto and "042917" in html
    assert "15 minutos" in texto
    assert texto.startswith("Olá, João!")


def test_codigo_novo_herda_as_tentativas_erradas(ambiente):
    """Pedir outro codigo a cada minuto nao zera a contagem: depois de 5
    erradas, nao sai codigo novo ate passar a janela de 24 h."""
    client, SessionLocal, enviados = ambiente
    _cadastrar(client)
    import models

    def passar(segundos):
        with SessionLocal() as db:
            registro = db.query(models.CodigoRedefinicaoSenha).one()
            registro.created_at = registro.created_at - timedelta(seconds=segundos)
            db.commit()

    def errado(c):
        return "000000" if c != "000000" else "111111"

    _pedir(client)
    for _ in range(3):
        assert _redefinir(client, errado(enviados[-1][2])).status_code == 400
    passar(61)
    _pedir(client)
    assert len(enviados) == 2
    for _ in range(2):
        assert _redefinir(client, errado(enviados[-1][2])).status_code == 400

    # 5 erradas na conta: o codigo certo nao entra e nao sai codigo novo.
    assert _redefinir(client, enviados[-1][2]).status_code == 400
    passar(61)
    assert _pedir(client).status_code == 202
    assert len(enviados) == 2

    # Passada a janela, sai codigo novo com a contagem zerada.
    passar(24 * 3600)
    _pedir(client)
    assert len(enviados) == 3
    assert _redefinir(client, enviados[-1][2]).status_code == 204


def test_tentativa_alem_do_limite_nao_conta_nem_entra(ambiente):
    """O UPDATE atomico so conta enquanto `tentativas < 5`: no limite, nem o
    codigo certo entra e a contagem nao passa de 5."""
    client, SessionLocal, enviados = ambiente
    _cadastrar(client)
    _pedir(client)
    import models

    with SessionLocal() as db:
        db.query(models.CodigoRedefinicaoSenha).update({"tentativas": 5})
        db.commit()
    assert _redefinir(client, enviados[0][2]).status_code == 400
    with SessionLocal() as db:
        assert db.query(models.CodigoRedefinicaoSenha).one().tentativas == 5


def test_nome_no_email_html_e_escapado():
    from services import email_service

    _, html = email_service._corpo_codigo("<b>Mal</b> Intencionado", "042917", 15)
    assert "<b>" not in html
    assert "&lt;b&gt;Mal&lt;/b&gt;" in html


def test_insert_perdido_na_corrida_devolve_none(ambiente, monkeypatch):
    """Dois pedidos juntos para o mesmo e-mail passam pelo SELECT sem achar
    linha e correm para o insert: o que perde esbarrava no unique de
    `user_id` e virava 500; agora devolve `None` (igual a reenvio cedo
    demais, sem e-mail novo)."""
    client, SessionLocal, _ = ambiente
    _cadastrar(client)
    import models
    from services import redefinicao_senha_service as srv

    # A linha do pedido que ganhou a corrida ja esta gravada.
    vencedor = SessionLocal()
    usuario = vencedor.query(models.User).filter_by(email=EMAIL).one()
    agora = datetime.now(timezone.utc).replace(tzinfo=None)
    vencedor.add(
        models.CodigoRedefinicaoSenha(
            user_id=usuario.id,
            codigo_hash="0" * 64,
            expires_at=agora + timedelta(minutes=15),
            tentativas=0,
            created_at=agora,
        )
    )
    vencedor.commit()
    vencedor.close()

    # O SELECT do pedido que perdeu rodou antes do insert vencedor.
    monkeypatch.setattr(srv, "_registro", lambda db, user_id: None)
    perdedor = SessionLocal()
    try:
        assert srv.pedir_codigo(perdedor, EMAIL) is None
        perdedor.commit()  # o savepoint desfez so o insert, a sessao saiu limpa
        assert perdedor.query(models.CodigoRedefinicaoSenha).count() == 1
    finally:
        perdedor.close()


def test_conta_apagada_no_meio_da_redefinicao_vira_codigo_invalido(ambiente, monkeypatch):
    """A conta some depois do UPDATE que conta a tentativa: reler o `usuario`
    expirado levantava ObjectDeletedError (500); agora vale o mesmo codigo
    invalido de sempre."""
    client, SessionLocal, enviados = ambiente
    _cadastrar(client)
    _pedir(client)
    codigo = enviados[0][2]

    import models
    from services import redefinicao_senha_service as srv

    db = SessionLocal()
    outra = SessionLocal()
    hash_original = srv.auth_service._hash_senha

    def apagar_conta_no_meio(senha):
        # O commit extra so solta a trava de leitura do `db` para a `outra`
        # gravar no SQLite; em MySQL a exclusao nao precisaria dessa licenca.
        db.commit()
        outra.query(models.CodigoRedefinicaoSenha).delete()
        outra.delete(outra.query(models.User).one())
        outra.commit()
        return hash_original(senha)

    monkeypatch.setattr(srv.auth_service, "_hash_senha", apagar_conta_no_meio)
    try:
        with pytest.raises(srv.CodigoInvalido):
            srv.redefinir(db, EMAIL, codigo, NOVA)
    finally:
        db.close()
        outra.close()


def test_linha_apagada_no_commit_da_tentativa_vira_codigo_invalido(ambiente, monkeypatch):
    """A linha do codigo some entre o UPDATE que conta a tentativa e o fim
    do commit dela (outra transacao pediu codigo novo ou apagou a conta):
    depois do commit `registro` esta expirado e qualquer releitura vira
    SELECT de refresh — ObjectDeletedError, que sem o tratamento virava
    500; agora vale o mesmo codigo invalido de sempre."""
    client, SessionLocal, enviados = ambiente
    _cadastrar(client)
    _pedir(client)
    codigo = enviados[0][2]

    import models
    from services import redefinicao_senha_service as srv

    db = SessionLocal()
    commit_real = db.commit

    def apagar_linha_no_commit(*args, **kwargs):
        # Sem `synchronize_session=False` o delete em lote marcaria
        # `registro` apagado na sessao e a releitura devolveria o valor
        # velho de memoria, sem chegar ao banco.
        db.query(models.CodigoRedefinicaoSenha).delete(synchronize_session=False)
        return commit_real(*args, **kwargs)

    monkeypatch.setattr(db, "commit", apagar_linha_no_commit)
    try:
        with pytest.raises(srv.CodigoInvalido):
            srv.redefinir(db, EMAIL, codigo, NOVA)
    finally:
        db.close()
