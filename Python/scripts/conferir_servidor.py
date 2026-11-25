"""Confere se o servidor está pronto para a loja (assinatura Apple + conta demo).

Uso, de dentro de `Python/` (na EC2, com o `.env` do serviço):

    python -m scripts.conferir_servidor

Imprime uma linha por item (`OK`/`FALTA` + motivo curto) e sai 0 se tudo
estiver OK, 1 se faltar algo. **Nunca imprime o valor de segredos** — só o
nome da variável que falta.

Cada checagem é uma função pura que recebe o ambiente (`dict`), a sessão do
banco e a pasta `Python/`; `main` só junta as três coisas e imprime.
"""

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import func, text

import models

TAMANHO_MINIMO_SEGREDO = 32
APPLE_OBRIGATORIAS = (
    "APPLE_BUNDLE_ID",
    "APPLE_APP_ID",
    "APPLE_ISSUER_ID",
    "APPLE_KEY_ID",
)


@dataclass
class Resultado:
    ok: bool
    nome: str
    motivo: str = ""


def _linha(resultado: Resultado) -> str:
    base = f"{'OK' if resultado.ok else 'FALTA'} {resultado.nome}"
    return f"{base}: {resultado.motivo}" if resultado.motivo else base


def _heads_alembic(pasta: Path) -> set[str]:
    """Revisões head da pasta `alembic/` (via `ScriptDirectory`)."""
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    config = Config()
    config.set_main_option("script_location", str(pasta / "alembic"))
    return set(ScriptDirectory.from_config(config).get_heads())


def conferir_banco(ambiente: dict, sessao, pasta: Path) -> Resultado:
    nome = "banco"
    if sessao is None:
        return Resultado(False, nome, "sessão não abriu")
    try:
        sessao.execute(text("SELECT 1"))
    except Exception as exc:
        # Só o tipo da exceção: a mensagem pode trazer host/usuário.
        return Resultado(False, nome, f"SELECT 1 falhou ({type(exc).__name__})")
    return Resultado(True, nome, "SELECT 1 respondeu")


def conferir_migracoes(ambiente: dict, sessao, pasta: Path) -> Resultado:
    nome = "migrations"
    if sessao is None:
        return Resultado(False, nome, "sem conexão com o banco")
    try:
        atuais = {
            linha[0]
            for linha in sessao.execute(
                text("SELECT version_num FROM alembic_version")
            )
        }
    except Exception as exc:
        return Resultado(
            False, nome, f"sem tabela alembic_version ({type(exc).__name__})"
        )
    try:
        heads = _heads_alembic(pasta)
    except Exception as exc:
        return Resultado(False, nome, f"alembic/ ilegível ({type(exc).__name__})")
    if not atuais:
        return Resultado(False, nome, "banco sem revisão gravada")
    if atuais == heads:
        return Resultado(True, nome, f"revisão {'/'.join(sorted(atuais))} = head")
    return Resultado(
        False,
        nome,
        f"banco em {'/'.join(sorted(atuais))}, head é {'/'.join(sorted(heads))}",
    )


def conferir_segredos_jwt(ambiente: dict, sessao, pasta: Path) -> Resultado:
    nome = "segredos JWT"
    pares = (
        ("SECRET_KEY", (ambiente.get("SECRET_KEY") or "").strip()),
        (
            "REFRESH_TOKEN_SECRET_KEY",
            (ambiente.get("REFRESH_TOKEN_SECRET_KEY") or "").strip(),
        ),
    )
    ausentes = [n for n, v in pares if not v]
    if ausentes:
        return Resultado(False, nome, f"{', '.join(ausentes)} ausente")
    curtos = [n for n, v in pares if len(v) < TAMANHO_MINIMO_SEGREDO]
    if curtos:
        return Resultado(
            False,
            nome,
            f"{', '.join(curtos)} com menos de {TAMANHO_MINIMO_SEGREDO} caracteres",
        )
    if pares[0][1] == pares[1][1]:
        return Resultado(False, nome, "SECRET_KEY e REFRESH_TOKEN_SECRET_KEY iguais")
    return Resultado(True, nome, "presentes, diferentes, 32+ caracteres")


def conferir_integracoes(ambiente: dict, sessao, pasta: Path) -> Resultado:
    nome = "S3 e IA"
    ausentes = [
        n
        for n in ("S3_BUCKET", "GEMINI_API_KEY")
        if not (ambiente.get(n) or "").strip()
    ]
    if ausentes:
        return Resultado(False, nome, f"{', '.join(ausentes)} ausente")
    return Resultado(True, nome, "S3_BUCKET e GEMINI_API_KEY presentes")


def conferir_apple(ambiente: dict, sessao, pasta: Path) -> Resultado:
    nome = "Apple"
    ausentes = [
        n for n in APPLE_OBRIGATORIAS if not (ambiente.get(n) or "").strip()
    ]
    if ausentes:
        return Resultado(False, nome, f"{', '.join(ausentes)} ausente")
    if (ambiente.get("APPLE_PRIVATE_KEY") or "").strip():
        return Resultado(True, nome, "APPLE_* presentes (chave na variável)")
    caminho = (ambiente.get("APPLE_PRIVATE_KEY_PATH") or "").strip()
    if not caminho:
        return Resultado(
            False, nome, "APPLE_PRIVATE_KEY (ou APPLE_PRIVATE_KEY_PATH) ausente"
        )
    arquivo = Path(caminho)
    if not arquivo.is_absolute():
        arquivo = pasta / arquivo
    try:
        with arquivo.open("rb"):
            pass
    except OSError:
        return Resultado(False, nome, "APPLE_PRIVATE_KEY_PATH ilegível")
    return Resultado(True, nome, "APPLE_* presentes (chave em arquivo)")


def conferir_certificados(ambiente: dict, sessao, pasta: Path) -> Resultado:
    nome = "certificados Apple"
    certificados = sorted((pasta / "certificados_apple").glob("*.cer"))
    if not certificados:
        return Resultado(False, nome, "nenhum .cer em certificados_apple/")
    return Resultado(True, nome, f"{len(certificados)} .cer")


def conferir_liberacao(ambiente: dict, sessao, pasta: Path) -> Resultado:
    """`BILLING_ENFORCEMENT` é só informativo; ids liberados têm que existir."""
    nome = "conta de demonstração"
    enforcement = (ambiente.get("BILLING_ENFORCEMENT") or "off").strip() or "off"
    info = f"BILLING_ENFORCEMENT={enforcement}"
    ids = [
        parte.strip()
        for parte in (ambiente.get("ACESSO_LIBERADO_USUARIOS") or "").split(",")
        if parte.strip()
    ]
    if not ids:
        return Resultado(
            False, nome, f"conta de demonstração não liberada ({info})"
        )
    if sessao is None:
        return Resultado(False, nome, f"sem conexão com o banco ({info})")
    inexistentes = [
        id_liberado
        for id_liberado in ids
        if sessao.query(models.User)
        .filter(func.lower(models.User.id) == id_liberado.lower())
        .first()
        is None
    ]
    if inexistentes:
        return Resultado(
            False, nome, f"ids sem usuário: {', '.join(inexistentes)} ({info})"
        )
    return Resultado(True, nome, f"{len(ids)} id(s) liberado(s) existe(m) ({info})")


TIMERS_DIARIOS = (
    "softspend-assinaturas.timer",
    "softspend-backup.timer",
)


def _estado_timer(nome: str) -> tuple[str, str] | None:
    """Par `(is-enabled, is-active)` do timer; `None` se não há `systemctl`."""
    estados = []
    for subcomando in ("is-enabled", "is-active"):
        try:
            saida = subprocess.run(
                ["systemctl", subcomando, nome],
                capture_output=True,
                text=True,
                timeout=5,
            )
        except FileNotFoundError:
            return None
        except (OSError, subprocess.TimeoutExpired):
            return ("desconhecido", "desconhecido")
        estados.append(saida.stdout.strip())
    return (estados[0], estados[1])


def conferir_timers(ambiente: dict, sessao, pasta: Path) -> Resultado:
    """Os timers diários (conciliação das assinaturas e backup) ficam
    desligados quando o `setup.sh` rodou antes das `APPLE_*`/`backup.env`;
    aqui isso vira FALTA em vez de passar em silêncio."""
    nome = "timers diários"
    desligados = []
    for timer in TIMERS_DIARIOS:
        estado = _estado_timer(timer)
        if estado is None:
            return Resultado(False, nome, "systemctl indisponível")
        if estado != ("enabled", "active"):
            resumo = (
                f"{estado[0]}/{estado[1]}"
                if estado[0]
                else "não instalado"
            )
            desligados.append(f"{timer} ({resumo})")
    if desligados:
        return Resultado(
            False,
            nome,
            f"{'; '.join(desligados)} — rodar o setup.sh de novo",
        )
    return Resultado(True, nome, "assinaturas e backup enabled/active")


CHECAGENS = (
    conferir_banco,
    conferir_migracoes,
    conferir_segredos_jwt,
    conferir_integracoes,
    conferir_apple,
    conferir_certificados,
    conferir_liberacao,
    conferir_timers,
)


def main(ambiente: dict | None = None, sessao=None, pasta=None) -> int:
    """Roda todas as checagens e imprime uma linha por item.

    `ambiente`, `sessao` e `pasta` existem para os testes; em uso real vêm de
    `os.environ` (com `.env`), `database.SessionLocal` e da pasta do script.
    """
    load_dotenv()
    ambiente = dict(os.environ) if ambiente is None else ambiente
    pasta = Path(__file__).resolve().parents[1] if pasta is None else Path(pasta)

    sessao_propria = sessao is None
    if sessao is None:
        try:
            from database import SessionLocal

            sessao = SessionLocal()
        except Exception:
            sessao = None
    try:
        resultados = [
            checar(ambiente, sessao, pasta) for checar in CHECAGENS
        ]
    finally:
        if sessao_propria and sessao is not None:
            sessao.close()

    for resultado in resultados:
        print(_linha(resultado))
    return 0 if all(r.ok for r in resultados) else 1


if __name__ == "__main__":
    sys.exit(main())
