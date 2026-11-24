"""Testes de `scripts/conferir_servidor.py` — a conferência de prontidão da loja.

Mesmo padrão de `test_conta_demo.py`: banco SQLite em `tmp_path`. A "pasta
Python/" também é falsa (`tmp_path/Python`), com `alembic/versions/` mínimo
e `certificados_apple/` com um `.cer`, para o head do Alembic e os
certificados dependerem só do teste.
"""

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

import models
from database import Base
from scripts import conferir_servidor as cs

HEAD = "revteste123"
USER_DEMO = "user-demo"

# Segredos sentinelas: nunca podem aparecer na saída.
SEGREDO_ACCESS = "access-SEGREDO-sentinel-0123456789abcdef"
SEGREDO_REFRESH = "refresh-SEGREDO-sentinel-0123456789abcde"
SEGREDO_APPLE = "apple-SEGREDO-sentinel-0123456789abcdefgh"


def _ambiente_ok() -> dict:
    return {
        "SECRET_KEY": SEGREDO_ACCESS,
        "REFRESH_TOKEN_SECRET_KEY": SEGREDO_REFRESH,
        "S3_BUCKET": "softspend-comprovantes",
        "GEMINI_API_KEY": "gemini-chave",
        "APPLE_BUNDLE_ID": "br.com.softspend.app",
        "APPLE_APP_ID": "123456789",
        "APPLE_ISSUER_ID": "issuer-id",
        "APPLE_KEY_ID": "key-id",
        "APPLE_PRIVATE_KEY": SEGREDO_APPLE,
        "BILLING_ENFORCEMENT": "on",
        "ACESSO_LIBERADO_USUARIOS": USER_DEMO,
    }


@pytest.fixture
def ambiente(tmp_path):
    """Banco SQLite + pasta Python/ falsa, tudo pronto para sair 0."""
    pasta = tmp_path / "Python"
    (pasta / "alembic" / "versions").mkdir(parents=True)
    (pasta / "alembic" / "versions" / f"{HEAD}_rev.py").write_text(
        f'revision = "{HEAD}"\ndown_revision = None\n', encoding="utf-8"
    )
    (pasta / "certificados_apple").mkdir()
    (pasta / "certificados_apple" / "raiz.cer").write_bytes(b"certificado")

    engine = create_engine(f"sqlite:///{tmp_path}/servidor.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.execute(
        text("CREATE TABLE alembic_version (version_num VARCHAR(32) NOT NULL)")
    )
    session.execute(
        text("INSERT INTO alembic_version (version_num) VALUES (:v)"),
        {"v": HEAD},
    )
    session.add(
        models.User(
            id=USER_DEMO, nome="Demo", username="demo", email="d@e.com",
            senha_hash="h",
        )
    )
    session.commit()

    try:
        yield {"session": session, "pasta": pasta, "env": _ambiente_ok()}
    finally:
        session.close()
        engine.dispose()


def _rodar(ambiente, **mudancas_env):
    env = dict(ambiente["env"])
    env.update(mudancas_env)
    return cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    )


def _linhas(capsys) -> str:
    return capsys.readouterr().out


def test_tudo_configurado_sai_0(ambiente, capsys):
    assert _rodar(ambiente) == 0
    saida = _linhas(capsys)
    assert "FALTA" not in saida
    assert saida.count("OK ") == len(cs.CHECAGENS)


def test_sem_apple_key_id_sai_1_e_linha_diz_falta(ambiente, capsys):
    env = dict(ambiente["env"])
    del env["APPLE_KEY_ID"]
    assert cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    ) == 1
    linhas = _linhas(capsys).splitlines()
    falta = [l for l in linhas if l.startswith("FALTA")]
    assert len(falta) == 1
    assert "APPLE_KEY_ID" in falta[0]


@pytest.mark.parametrize(
    "ausentes",
    [("S3_BUCKET",), ("GEMINI_API_KEY",), ("S3_BUCKET", "GEMINI_API_KEY")],
)
def test_integracoes_ausentes_dao_falta(ambiente, capsys, ausentes):
    env = dict(ambiente["env"])
    for nome in ausentes:
        del env[nome]
    assert cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    ) == 1
    falta = [l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")]
    assert len(falta) == 1
    for nome in ausentes:
        assert nome in falta[0]


def test_main_sem_sessao_sai_1_sem_traceback(ambiente, capsys, monkeypatch):
    """Banco fora do ar: a fábrica de sessão falha, `main` segue sem sessão,
    sai 1 com FALTA nas checagens de banco e nenhum traceback na saída."""
    import database

    def _fora_do_ar():
        raise RuntimeError("banco fora do ar")

    monkeypatch.setattr(database, "SessionLocal", _fora_do_ar)
    assert cs.main(ambiente=ambiente["env"], pasta=ambiente["pasta"]) == 1
    capturado = capsys.readouterr()
    falta = [l for l in capturado.out.splitlines() if l.startswith("FALTA")]
    assert any("sessão não abriu" in l for l in falta)
    assert "Traceback" not in capturado.out
    assert "Traceback" not in capturado.err


@pytest.mark.parametrize("revisao", ["outra-revisao", None])
def test_revisao_diferente_do_head_da_falta(ambiente, capsys, revisao):
    session = ambiente["session"]
    session.execute(text("DELETE FROM alembic_version"))
    if revisao is not None:
        session.execute(
            text("INSERT INTO alembic_version (version_num) VALUES (:v)"),
            {"v": revisao},
        )
    session.commit()

    assert _rodar(ambiente) == 1
    falta = [
        l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")
    ]
    assert any("migrations" in l for l in falta)


def test_id_liberado_inexistente_da_falta(ambiente, capsys):
    assert _rodar(ambiente, ACESSO_LIBERADO_USUARIOS="id-que-nao-existe") == 1
    falta = [
        l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")
    ]
    assert any("id-que-nao-existe" in l for l in falta)


@pytest.mark.parametrize("vazio", [None, "", "   "])
def test_acesso_liberado_vazio_da_falta(ambiente, capsys, vazio):
    env = dict(ambiente["env"])
    if vazio is None:
        del env["ACESSO_LIBERADO_USUARIOS"]
    else:
        env["ACESSO_LIBERADO_USUARIOS"] = vazio
    assert cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    ) == 1
    assert "conta de demonstração não liberada" in _linhas(capsys)


def test_segredos_nao_aparecem_na_saida(ambiente, capsys):
    # Roda uma vez OK e outra com várias faltas; em nenhuma sai segredo.
    assert _rodar(ambiente) == 0
    assert _rodar(
        ambiente,
        APPLE_KEY_ID="",
        ACESSO_LIBERADO_USUARIOS="id-que-nao-existe",
    ) == 1
    capturado = capsys.readouterr()
    for segredo in (SEGREDO_ACCESS, SEGREDO_REFRESH, SEGREDO_APPLE):
        assert segredo not in capturado.out
        assert segredo not in capturado.err


def test_apple_private_key_path_legivel(ambiente, capsys, tmp_path):
    chave = tmp_path / "AuthKey.p8"
    chave.write_text("conteudo-da-chave", encoding="utf-8")
    env = dict(ambiente["env"])
    del env["APPLE_PRIVATE_KEY"]
    env["APPLE_PRIVATE_KEY_PATH"] = str(chave)
    assert cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    ) == 0

    env["APPLE_PRIVATE_KEY_PATH"] = str(tmp_path / "nao-existe.p8")
    assert cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    ) == 1
    assert "APPLE_PRIVATE_KEY_PATH ilegível" in _linhas(capsys)


def test_segredos_curtos_ou_iguais_dao_falta(ambiente, capsys):
    assert _rodar(ambiente, SECRET_KEY="curta") == 1
    assert "32 caracteres" in _linhas(capsys)
    assert _rodar(ambiente, REFRESH_TOKEN_SECRET_KEY=SEGREDO_ACCESS) == 1
    assert "iguais" in _linhas(capsys)


def test_sem_certificado_da_falta(ambiente, capsys):
    for cer in (ambiente["pasta"] / "certificados_apple").glob("*.cer"):
        cer.unlink()
    assert _rodar(ambiente) == 1
    assert "certificados_apple" in _linhas(capsys)


def test_billing_enforcement_aparece_mas_nao_e_falta(ambiente, capsys):
    env = dict(ambiente["env"])
    del env["BILLING_ENFORCEMENT"]
    assert cs.main(
        ambiente=env, sessao=ambiente["session"], pasta=ambiente["pasta"]
    ) == 0
    assert "BILLING_ENFORCEMENT=off" in _linhas(capsys)
