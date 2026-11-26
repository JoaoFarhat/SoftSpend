"""Testes de `scripts/conferir_servidor.py` — a conferência de prontidão da loja.

Mesmo padrão de `test_conta_demo.py`: banco SQLite em `tmp_path`. A "pasta
Python/" também é falsa (`tmp_path/Python`), com `alembic/versions/` mínimo
e `certificados_apple/` com um `.cer`, para o head do Alembic e os
certificados dependerem só do teste.
"""

import os
import subprocess
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

import models
from database import Base
from scripts import conferir_servidor as cs

HEAD = "revteste123"
USER_DEMO = "user-demo"

# Horário de início do serviço usado pelo fixture: depois de qualquer
# `.env` criado agora, para a checagem de reinício sair OK por padrão.
INICIO_SERVICO = 1_900_000_000

# Segredos sentinelas: nunca podem aparecer na saída.
SEGREDO_ACCESS = "access-SEGREDO-sentinel-0123456789abcdef"
SEGREDO_REFRESH = "refresh-SEGREDO-sentinel-0123456789abcde"
SEGREDO_APPLE = "apple-SEGREDO-sentinel-0123456789abcdefgh"
ARN_SNS = "arn:aws:sns:sa-east-1:123456789012:softspend-alertas"


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
def ambiente(tmp_path, monkeypatch):
    """Banco SQLite + pasta Python/ falsa, tudo pronto para sair 0."""
    # Os timers só existem na EC2; nos testes, os três ligados por padrão.
    monkeypatch.setattr(
        cs, "_estado_timer", lambda nome: ("enabled", "active")
    )
    # Idem o `systemctl show` do serviço: início depois do `.env` (OK).
    monkeypatch.setattr(cs, "_inicio_servico", lambda: INICIO_SERVICO)
    # O alerta.env é do root na EC2; nos testes, um temporário com tópico.
    alerta = tmp_path / "alerta.env"
    alerta.write_text(f"ALERTA_SNS_TOPICO={ARN_SNS}\n", encoding="utf-8")
    monkeypatch.setattr(cs, "ARQUIVO_ALERTA", alerta)
    pasta = tmp_path / "Python"
    (pasta / "alembic" / "versions").mkdir(parents=True)
    (pasta / "alembic" / "versions" / f"{HEAD}_rev.py").write_text(
        f'revision = "{HEAD}"\ndown_revision = None\n', encoding="utf-8"
    )
    (pasta / "certificados_apple").mkdir()
    (pasta / "certificados_apple" / "raiz.cer").write_bytes(b"certificado")
    (pasta / ".env").write_text("SECRET_KEY=x\n", encoding="utf-8")

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
    for segredo in (SEGREDO_ACCESS, SEGREDO_REFRESH, SEGREDO_APPLE, ARN_SNS):
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


def test_timers_ligados_dao_ok(ambiente, capsys):
    assert _rodar(ambiente) == 0
    assert any(
        l.startswith("OK timers") for l in _linhas(capsys).splitlines()
    )


def test_timer_assinaturas_desligado_da_falta(ambiente, capsys, monkeypatch):
    def _estado(nome):
        if nome == "softspend-assinaturas.timer":
            return ("disabled", "inactive")
        return ("enabled", "active")

    monkeypatch.setattr(cs, "_estado_timer", _estado)
    assert _rodar(ambiente) == 1
    falta = [l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")]
    assert len(falta) == 1
    assert "softspend-assinaturas.timer" in falta[0]
    assert "setup.sh" in falta[0]


def test_timer_restauracao_desligado_da_falta(ambiente, capsys, monkeypatch):
    def _estado(nome):
        if nome == "softspend-backup-teste.timer":
            return ("disabled", "inactive")
        return ("enabled", "active")

    monkeypatch.setattr(cs, "_estado_timer", _estado)
    assert _rodar(ambiente) == 1
    falta = [l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")]
    assert len(falta) == 1
    assert "softspend-backup-teste.timer" in falta[0]
    assert "setup.sh" in falta[0]


def test_sem_systemctl_da_falta(ambiente, capsys, monkeypatch):
    monkeypatch.setattr(cs, "_estado_timer", lambda nome: None)
    assert _rodar(ambiente) == 1
    assert "systemctl indisponível" in _linhas(capsys)


# `conferir_alertas`: o alerta.env de verdade é do root na EC2; aqui cada
# caso usa um arquivo temporário (ou um objeto que simula PermissionError).


def _alerta_env(tmp_path, conteudo: str):
    arquivo = tmp_path / "alerta.env"
    arquivo.write_text(conteudo, encoding="utf-8")
    return arquivo


def test_alerta_com_topico_da_ok_sem_mostrar_arn(tmp_path):
    arquivo = _alerta_env(tmp_path, f"ALERTA_SNS_TOPICO={ARN_SNS}\n")
    resultado = cs.conferir_alertas({}, None, None, arquivo)
    linha = cs._linha(resultado)
    assert resultado.ok
    assert linha.startswith("OK")
    assert ARN_SNS not in linha


@pytest.mark.parametrize(
    "conteudo",
    [
        "ALERTA_SNS_TOPICO=\n",
        "ALERTA_SNS_TOPICO=   \n",
        "# alerta.env sem o tópico\n",
        f"OUTRA_VARIAVEL={ARN_SNS}\n",
    ],
)
def test_alerta_vazio_ou_ausente_da_falta(tmp_path, conteudo):
    arquivo = _alerta_env(tmp_path, conteudo)
    linha = cs._linha(cs.conferir_alertas({}, None, None, arquivo))
    assert linha.startswith("FALTA")
    assert "alertas desligados" in linha
    assert "ALERTA_SNS_TOPICO" in linha
    assert ARN_SNS not in linha


def test_alerta_arquivo_inexistente_da_falta(tmp_path):
    arquivo = tmp_path / "sem-pasta" / "alerta.env"
    linha = cs._linha(cs.conferir_alertas({}, None, None, arquivo))
    assert linha.startswith("FALTA")
    assert "arquivo não existe" in linha
    assert "setup.sh" in linha
    assert ARN_SNS not in linha


def test_alerta_sem_permissao_da_falta():
    class _SemPermissao:
        def read_text(self, encoding="utf-8"):
            raise PermissionError("acesso negado")

    linha = cs._linha(cs.conferir_alertas({}, None, None, _SemPermissao()))
    assert linha.startswith("FALTA")
    assert "sem permissão" in linha
    assert "sudo" in linha
    assert ARN_SNS not in linha


def test_alerta_oserror_da_falta(tmp_path, monkeypatch):
    """OSError genérico (não PermissionError nem FileNotFoundError, que têm
    ramo próprio) vira FALTA — sem esse ramo, um alerta.env ilegível
    derrubava o script e o servidor parecia conferido."""
    arquivo = _alerta_env(
        tmp_path, "ALERTA_SNS_TOPICO=arn:aws:sns:sa-east-1:123:x\n"
    )

    def _read_text(*args, **kwargs):
        raise OSError("disco")

    monkeypatch.setattr(Path, "read_text", _read_text)
    resultado = cs.conferir_alertas({}, None, tmp_path, arquivo=arquivo)
    assert resultado.ok is False
    assert resultado.motivo == "arquivo ilegível (OSError)"
    assert "arn:" not in resultado.motivo


def test_alerta_valor_nao_arn_da_falta(tmp_path):
    arquivo = _alerta_env(tmp_path, "ALERTA_SNS_TOPICO=email@exemplo.com\n")
    linha = cs._linha(cs.conferir_alertas({}, None, None, arquivo))
    assert linha.startswith("FALTA")
    assert "ARN do SNS" in linha
    assert "email@exemplo.com" not in linha
    assert ARN_SNS not in linha


# `_estado_timer` de verdade (o que roda na EC2), com `subprocess.run`
# trocado por monkeypatch — os testes acima substituem a função inteira.


def test_estado_timer_sem_systemctl_devolve_none(monkeypatch):
    def _run(*args, **kwargs):
        raise FileNotFoundError("systemctl")

    monkeypatch.setattr(cs.subprocess, "run", _run)
    assert cs._estado_timer("softspend-backup.timer") is None


def test_estado_timer_timeout_devolve_desconhecido(monkeypatch):
    def _run(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd="systemctl", timeout=5)

    monkeypatch.setattr(cs.subprocess, "run", _run)
    assert cs._estado_timer("softspend-backup.timer") == (
        "desconhecido",
        "desconhecido",
    )


def test_estado_timer_enabled_active(monkeypatch):
    saidas = {"is-enabled": "enabled\n", "is-active": "active\n"}

    def _run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout=saidas[cmd[1]])

    monkeypatch.setattr(cs.subprocess, "run", _run)
    assert cs._estado_timer("softspend-backup.timer") == ("enabled", "active")


def test_is_enabled_vazio_diz_nao_instalado_no_falta(monkeypatch):
    """Unit não instalada: `is-enabled` sai vazio e `is-active` sai
    "inactive"; o FALTA diz "não instalado" em vez de "(/inactive)"."""

    def _run(cmd, **kwargs):
        stdout = "" if cmd[1] == "is-enabled" else "inactive\n"
        return subprocess.CompletedProcess(cmd, 1, stdout=stdout)

    monkeypatch.setattr(cs.subprocess, "run", _run)
    linha = cs._linha(cs.conferir_timers({}, None, None))
    assert linha.startswith("FALTA")
    assert "não instalado" in linha
    assert "(/" not in linha


def test_env_mais_novo_que_o_inicio_da_falta(ambiente, capsys):
    """`.env` editado depois do início do serviço: a API roda os valores
    antigos e a checagem manda reiniciar."""
    arquivo_env = ambiente["pasta"] / ".env"
    futuro = INICIO_SERVICO + 3600
    os.utime(arquivo_env, (futuro, futuro))
    assert _rodar(ambiente) == 1
    falta = [l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")]
    assert len(falta) == 1
    assert "restart" in falta[0]


def test_env_mais_velho_que_o_inicio_da_ok(ambiente, capsys):
    arquivo_env = ambiente["pasta"] / ".env"
    passado = INICIO_SERVICO - 3600
    os.utime(arquivo_env, (passado, passado))
    assert _rodar(ambiente) == 0
    assert "API iniciada depois" in _linhas(capsys)


def test_env_no_mesmo_segundo_do_inicio_da_ok(ambiente, capsys):
    """`.env` gravado na fração do mesmo segundo do restart (mtime
    INICIO + 0,5 s): o início vem truncado em segundos do
    `systemctl --timestamp=unix`, então a fração a mais não pode dar
    FALTA falso de ".env mudou depois que a API iniciou"."""
    arquivo_env = ambiente["pasta"] / ".env"
    mesmo_segundo = INICIO_SERVICO + 0.5
    os.utime(arquivo_env, (mesmo_segundo, mesmo_segundo))
    assert _rodar(ambiente) == 0
    assert "API iniciada depois" in _linhas(capsys)


def test_env_um_segundo_depois_do_inicio_da_falta(ambiente, capsys):
    arquivo_env = ambiente["pasta"] / ".env"
    depois = INICIO_SERVICO + 1
    os.utime(arquivo_env, (depois, depois))
    assert _rodar(ambiente) == 1
    falta = [l for l in _linhas(capsys).splitlines() if l.startswith("FALTA")]
    assert len(falta) == 1
    assert "restart" in falta[0]


def test_servico_parado_da_falta(ambiente, capsys, monkeypatch):
    monkeypatch.setattr(cs, "_inicio_servico", lambda: "")
    assert _rodar(ambiente) == 1
    assert "parado" in _linhas(capsys)


def test_reinicio_sem_systemctl_da_falta(ambiente, capsys, monkeypatch):
    monkeypatch.setattr(cs, "_inicio_servico", lambda: None)
    assert _rodar(ambiente) == 1
    assert "systemctl indisponível" in _linhas(capsys)


# `_inicio_servico` de verdade (o que roda na EC2), com `subprocess.run`
# trocado por monkeypatch — os testes acima substituem a função inteira.


def test_inicio_servico_converte_timestamp_unix(monkeypatch):
    def _run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="@1732530000\n")

    monkeypatch.setattr(cs.subprocess, "run", _run)
    assert cs._inicio_servico() == 1732530000


def test_inicio_servico_vazio_devolve_vazio(monkeypatch):
    def _run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    monkeypatch.setattr(cs.subprocess, "run", _run)
    assert cs._inicio_servico() == ""


def test_inicio_servico_sem_systemctl_devolve_none(monkeypatch):
    def _run(*args, **kwargs):
        raise FileNotFoundError("systemctl")

    monkeypatch.setattr(cs.subprocess, "run", _run)
    assert cs._inicio_servico() is None
