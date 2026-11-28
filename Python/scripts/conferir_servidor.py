"""Confere se o servidor está pronto para a loja (assinatura Apple + conta demo).

Uso, de dentro de `Python/` (na EC2, com o `.env` do serviço):

    python -m scripts.conferir_servidor

Imprime uma linha por item (`OK`/`FALTA` + motivo curto) e sai 0 se tudo
estiver OK, 1 se faltar algo. **Nunca imprime o valor de segredos** — só o
nome da variável que falta.

Cada checagem é uma função pura que recebe o ambiente (`dict`), a sessão do
banco e a pasta `Python/`; `main` só junta as três coisas e imprime.
"""

import ipaddress
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


def conferir_proxy(ambiente: dict, sessao, pasta: Path) -> Resultado:
    """Atrás do nginx com `TRUST_PROXY=false`, o `limiter.get_real_ip` vê
    todo pedido vindo de 127.0.0.1: o teto de 5 logins e 3 cadastros por
    minuto passa a valer para o app inteiro. Um `.env` refeito a partir do
    `.env.example` (que vem com `false`) cai nesse caso sem ninguém ver."""
    nome = "proxy"
    # A mesma conta do limiter.py (sem strip), para nunca discordar da API.
    if ambiente.get("TRUST_PROXY", "false").lower() != "true":
        return Resultado(
            False,
            nome,
            "TRUST_PROXY não é true: "
            "os limites de login contam todos como 127.0.0.1",
        )
    try:
        redes = tuple(
            ipaddress.ip_network(valor.strip())
            for valor in ambiente.get(
                "TRUSTED_PROXY_IPS", "127.0.0.1,::1"
            ).split(",")
            if valor.strip()
        )
    except ValueError:
        return Resultado(False, nome, "TRUSTED_PROXY_IPS sem 127.0.0.1")
    loopback = ipaddress.ip_address("127.0.0.1")
    if not any(loopback in rede for rede in redes):
        return Resultado(False, nome, "TRUSTED_PROXY_IPS sem 127.0.0.1")
    return Resultado(True, nome, "TRUST_PROXY=true")


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


def conferir_email(ambiente: dict, sessao, pasta: Path) -> Resultado:
    """`EMAIL_REMETENTE` vazia derruba o "Esqueci minha senha" com 503. Sem
    `SES_REGION` o `email_service._cliente` cai em `us-east-1`, mas o domínio
    está verificado só em `sa-east-1`: o envio falha em background, a rota
    segue respondendo 202 e a pessoa nunca recebe o código."""
    nome = "e-mail SES"
    if not (ambiente.get("EMAIL_REMETENTE") or "").strip():
        return Resultado(
            False,
            nome,
            "EMAIL_REMETENTE ausente — "
            "POST /auth/senha/esqueci responde 503",
        )
    if not (ambiente.get("SES_REGION") or "").strip():
        return Resultado(
            False,
            nome,
            "SES_REGION ausente — SES cai em us-east-1 "
            "e o envio falha em background",
        )
    return Resultado(True, nome, "EMAIL_REMETENTE e SES_REGION presentes")


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


TIMERS = (
    "softspend-assinaturas.timer",
    "softspend-backup.timer",
    "softspend-backup-teste.timer",
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


def _inicio_servico() -> int | str | None:
    """Horário Unix em que o `softspend.service` iniciou pela última vez.

    `None` se não há `systemctl`; "desconhecido" em outro erro de
    `subprocess` ou saída ilegível; `""` se o serviço está parado (saída
    vazia). Com `--timestamp=unix` o valor vem como `@1732530000`.
    """
    try:
        saida = subprocess.run(
            [
                "systemctl", "show", "softspend",
                "--property=ActiveEnterTimestamp",
                "--value", "--timestamp=unix",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except FileNotFoundError:
        return None
    except (OSError, subprocess.TimeoutExpired):
        return "desconhecido"
    texto = saida.stdout.strip()
    if not texto:
        return ""
    try:
        return int(texto.lstrip("@"))
    except ValueError:
        return "desconhecido"


def conferir_timers(ambiente: dict, sessao, pasta: Path) -> Resultado:
    """Os timers diários (conciliação das assinaturas e backup) e o teste
    mensal de restauração ficam desligados quando o `setup.sh` rodou antes
    das `APPLE_*`, do `backup.env` ou do `restore.cnf`; aqui isso vira
    FALTA em vez de passar em silêncio."""
    nome = "timers"
    desligados = []
    for timer in TIMERS:
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
    return Resultado(
        True, nome, "assinaturas, backup e teste de restauração enabled/active"
    )


ARQUIVO_ALERTA = Path("/etc/softspend/alerta.env")


def conferir_alertas(
    ambiente: dict, sessao, pasta: Path, arquivo: Path | None = None
) -> Resultado:
    """Os avisos por e-mail nascem desligados: o `setup.sh` instala o
    `alerta.env` com `ALERTA_SNS_TOPICO` vazio, e sem tópico o `alertar.py`
    não publica nada — o backup pode falhar sem avisar ninguém. O ARN
    nunca aparece na saída (o arquivo é do root e fala com a AWS)."""
    nome = "alertas por e-mail"
    arquivo = ARQUIVO_ALERTA if arquivo is None else arquivo
    try:
        conteudo = arquivo.read_text(encoding="utf-8")
    except PermissionError:
        return Resultado(
            False,
            nome,
            "sem permissão para ler (o arquivo é do root) — rodar com sudo",
        )
    except FileNotFoundError:
        return Resultado(False, nome, "arquivo não existe — rodar o setup.sh")
    except OSError as exc:
        return Resultado(
            False, nome, f"arquivo ilegível ({type(exc).__name__})"
        )
    topico = ""
    for linha in conteudo.splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#"):
            continue
        chave, _, valor = linha.partition("=")
        if chave.strip() == "ALERTA_SNS_TOPICO":
            topico = valor.strip().strip('"').strip("'")
    if not topico:
        return Resultado(
            False,
            nome,
            f"alertas desligados (ALERTA_SNS_TOPICO vazio em {arquivo})",
        )
    if not topico.startswith("arn:aws:sns:"):
        return Resultado(False, nome, "valor não parece um ARN do SNS")
    return Resultado(True, nome, "ALERTA_SNS_TOPICO com ARN do SNS")


ARQUIVO_NGINX = Path("/etc/nginx/sites-available/softspend")


def conferir_nginx(
    ambiente: dict, sessao, pasta: Path, arquivo: Path | None = None
) -> Resultado:
    """O deploy não copia nem recarrega o nginx: esquecido o passo manual,
    o servidor fica com o tempo-limite antigo, a leitura de fatura em PDF
    volta 504 para quem usa e este script dizia tudo OK. Aqui o arquivo
    instalado é comparado byte a byte com o do repositório. O conteúdo dos
    arquivos nunca aparece na saída."""
    nome = "nginx"
    instalado = ARQUIVO_NGINX if arquivo is None else arquivo
    repositorio = pasta.parent / "deploy" / "ec2" / "nginx-softspend.conf"
    try:
        conteudo_instalado = instalado.read_bytes()
    except FileNotFoundError:
        return Resultado(
            False, nome, "nginx do SoftSpend não instalado — rodar o setup.sh"
        )
    except OSError as exc:
        return Resultado(
            False, nome, f"arquivo ilegível ({type(exc).__name__})"
        )
    try:
        conteudo_repositorio = repositorio.read_bytes()
    except FileNotFoundError:
        return Resultado(
            False, nome, "nginx-softspend.conf não encontrado no repositório"
        )
    except OSError as exc:
        return Resultado(
            False, nome, f"arquivo ilegível ({type(exc).__name__})"
        )
    if conteudo_instalado == conteudo_repositorio:
        return Resultado(True, nome, "nginx igual ao do repositório")
    return Resultado(
        False,
        nome,
        "nginx diferente do repositório — "
        "sudo cp ~/SoftSpend/deploy/ec2/nginx-softspend.conf "
        "/etc/nginx/sites-available/softspend "
        "&& sudo nginx -t && sudo systemctl reload nginx",
    )


def conferir_reinicio(ambiente: dict, sessao, pasta: Path) -> Resultado:
    """O `softspend.service` lê o `.env` só ao iniciar (`EnvironmentFile`),
    mas este script lê o `.env` direto do arquivo: quem edita as `APPLE_*`
    ou `ACESSO_LIBERADO_USUARIOS` e esquece o restart veria tudo OK com a
    API rodando os valores antigos."""
    nome = "reinício do serviço"
    inicio = _inicio_servico()
    if inicio is None:
        return Resultado(False, nome, "systemctl indisponível")
    if inicio == "":
        return Resultado(False, nome, "serviço softspend parado")
    if not isinstance(inicio, int):
        return Resultado(False, nome, "início do serviço desconhecido")
    try:
        # O início vem em segundos inteiros (`--timestamp=unix`); truncar o
        # mtime evita o FALTA falso de quem edita o .env e reinicia no
        # mesmo segundo.
        mudanca_env = int((pasta / ".env").stat().st_mtime)
    except OSError:
        return Resultado(False, nome, ".env não encontrado")
    if mudanca_env > inicio:
        return Resultado(
            False,
            nome,
            "o .env mudou depois que a API iniciou — "
            "rodar sudo systemctl restart softspend",
        )
    return Resultado(
        True, nome, "API iniciada depois da última mudança do .env"
    )


CHECAGENS = (
    conferir_banco,
    conferir_migracoes,
    conferir_segredos_jwt,
    conferir_proxy,
    conferir_integracoes,
    conferir_email,
    conferir_apple,
    conferir_certificados,
    conferir_liberacao,
    conferir_timers,
    conferir_alertas,
    conferir_nginx,
    conferir_reinicio,
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
