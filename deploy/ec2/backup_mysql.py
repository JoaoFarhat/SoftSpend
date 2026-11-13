#!/usr/bin/env python3
"""Ajudante do backup diário do MySQL (docs/backup-mysql.md, §3).

Chamado pelo `backup-mysql.sh`, que faz o `mysqldump | gzip`. Aqui fica o que
dá para testar com `pytest`:

- `nome`      imprime o nome do próximo dump (`softspend-AAAAMMDDTHHMMSSZ.sql.gz`);
- `espaco`    confere o espaço livre na pasta (2x o último dump, mínimo 50 MB);
- `validar`   confere o dump (gzip íntegro, termina com `-- Dump completed`,
              maior que 10 KB) e grava o `.meta.json` ao lado;
- `enviar`    sobe dump e meta ao S3 em `<destino>/AAAA/MM/` e confere o tamanho;
- `limpar`    apaga os dumps locais mais antigos, mantendo os N últimos.

Só usa a biblioteca padrão e o `boto3` (já na venv da API). Nunca lê o `.env`
da API nem as variáveis `S3_*` (são as chaves do bucket dos comprovantes): o
envio usa a função IAM da EC2.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import sys
import zlib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

PREFIXO = "softspend-"
SUFIXO_DUMP = ".sql.gz"
SUFIXO_META = ".meta.json"
FORMATO_DATA = "%Y%m%dT%H%M%SZ"
NOME_RE = re.compile(r"^softspend-(\d{8}T\d{6}Z)\.sql\.gz$")

TAMANHO_MINIMO = 10 * 1024  # 10 KB
ESPACO_MINIMO = 50 * 1024 * 1024  # 50 MB, quando ainda não há dump anterior
DESTINOS = ("diario", "pre-migration")
TABELAS_CONTADAS = ("users", "ciclos", "dias", "gastos_dia")
FIM_DO_DUMP = b"-- Dump completed"


class ErroBackup(Exception):
    """Falha com mensagem clara; o CLI imprime e sai com código 1."""


# ---------------------------------------------------------------------------
# Nome do arquivo
# ---------------------------------------------------------------------------


def nome_arquivo(agora: datetime | None = None) -> str:
    agora = agora or datetime.now(timezone.utc)
    if agora.tzinfo is None:
        raise ValueError("agora precisa ter fuso (UTC)")
    return f"{PREFIXO}{agora.astimezone(timezone.utc).strftime(FORMATO_DATA)}{SUFIXO_DUMP}"


def data_do_nome(nome: str) -> datetime:
    m = NOME_RE.match(Path(nome).name)
    if not m:
        raise ErroBackup(f"nome de dump inválido: {nome!r}")
    return datetime.strptime(m.group(1), FORMATO_DATA).replace(tzinfo=timezone.utc)


def caminho_meta(dump: Path) -> Path:
    return dump.with_name(dump.name[: -len(SUFIXO_DUMP)] + SUFIXO_META)


def chave_s3(nome: str, destino: str) -> str:
    if destino not in DESTINOS:
        raise ErroBackup(f"destino inválido: {destino!r} (use {', '.join(DESTINOS)})")
    data = data_do_nome(nome)
    return f"{destino}/{data:%Y}/{data:%m}/{Path(nome).name}"


# ---------------------------------------------------------------------------
# Espaço livre
# ---------------------------------------------------------------------------


def dumps_locais(pasta: Path) -> list[Path]:
    """Dumps completos da pasta, do mais antigo para o mais novo."""
    if not pasta.is_dir():
        return []
    return sorted(p for p in pasta.iterdir() if p.is_file() and NOME_RE.match(p.name))


def conferir_espaco(pasta: Path, livre: int | None = None) -> int:
    """Devolve o espaço exigido; lança se o livre for menor."""
    dumps = dumps_locais(pasta)
    exigido = max(ESPACO_MINIMO, 2 * dumps[-1].stat().st_size) if dumps else ESPACO_MINIMO
    if livre is None:
        livre = shutil.disk_usage(pasta).free
    if livre < exigido:
        raise ErroBackup(
            f"espaço livre insuficiente em {pasta}: {livre // (1024 * 1024)} MB livres, "
            f"precisa de pelo menos {exigido // (1024 * 1024)} MB "
            "(2 vezes o último dump, mínimo 50 MB)"
        )
    return exigido


# ---------------------------------------------------------------------------
# Validação e metadados
# ---------------------------------------------------------------------------


def contar_tuplas(valores: bytes) -> int:
    """Conta as linhas de um `INSERT ... VALUES (...),(...);` do mysqldump.

    Conta os `(` de nível zero fora de string. O mysqldump escreve strings
    entre aspas simples com escape por barra invertida, então `),(` dentro de
    um texto não conta.
    """
    total = 0
    profundidade = 0
    em_string = False
    escape = False
    for c in valores:
        if em_string:
            if escape:
                escape = False
            elif c == 0x5C:  # \
                escape = True
            elif c == 0x27:  # '
                em_string = False
            continue
        if c == 0x27:
            em_string = True
        elif c == 0x28:  # (
            if profundidade == 0:
                total += 1
            profundidade += 1
        elif c == 0x29:  # )
            profundidade -= 1
    return total


def primeiras_strings(valores: bytes) -> list[str]:
    """Primeiro campo (string) de cada tupla, usado para `alembic_version`."""
    return [m.decode("utf-8", "replace") for m in re.findall(rb"\('((?:[^'\\]|\\.)*)'", valores)]


INSERT_RE = re.compile(rb"^INSERT INTO `([^`]+)` VALUES ")
CREATE_RE = re.compile(rb"^CREATE TABLE `([^`]+)`")
VERSAO_RE = re.compile(rb"^-- Server version\s+(.+?)\s*$")


@dataclass
class Resumo:
    versao_mysql: str | None
    alembic_version: str | None
    contagens: dict[str, int]
    sha256: str
    tamanho: int


def validar_dump(dump: Path) -> Resumo:
    """Lê o dump inteiro uma vez: valida e tira os números do `.meta.json`.

    As contagens vêm do próprio dump (e não de um `SELECT COUNT(*)` à parte),
    então batem com o que foi copiado mesmo com a API gravando durante o dump.
    """
    if not dump.is_file():
        raise ErroBackup(f"dump não encontrado: {dump}")
    tamanho = dump.stat().st_size
    if tamanho <= TAMANHO_MINIMO:
        raise ErroBackup(f"dump pequeno demais ({tamanho} bytes, mínimo {TAMANHO_MINIMO}): {dump}")

    sha = hashlib.sha256()
    with dump.open("rb") as f:
        for bloco in iter(lambda: f.read(1024 * 1024), b""):
            sha.update(bloco)

    versao = None
    alembic: list[str] = []
    criadas: set[str] = set()
    contagens: dict[str, int] = {}
    ultima = b""
    try:
        with gzip.open(dump, "rb") as f:
            for linha in f:
                if linha.strip():
                    ultima = linha.strip()
                if versao is None:
                    m = VERSAO_RE.match(linha)
                    if m:
                        versao = m.group(1).decode("utf-8", "replace")
                        continue
                m = CREATE_RE.match(linha)
                if m:
                    criadas.add(m.group(1).decode())
                    continue
                m = INSERT_RE.match(linha)
                if not m:
                    continue
                tabela = m.group(1).decode()
                valores = linha[m.end():]
                if tabela in TABELAS_CONTADAS:
                    contagens[tabela] = contagens.get(tabela, 0) + contar_tuplas(valores)
                elif tabela == "alembic_version":
                    alembic.extend(primeiras_strings(valores))
    except (OSError, EOFError, zlib.error) as e:
        raise ErroBackup(f"gzip corrompido em {dump}: {e}") from e

    if not ultima.startswith(FIM_DO_DUMP):
        raise ErroBackup(f"dump incompleto (não termina com '-- Dump completed'): {dump}")
    faltando = [t for t in TABELAS_CONTADAS if t not in criadas]
    if faltando:
        raise ErroBackup(f"tabelas ausentes no dump: {', '.join(faltando)}")

    return Resumo(
        versao_mysql=versao,
        alembic_version=",".join(alembic) if alembic else None,
        contagens={t: contagens.get(t, 0) for t in TABELAS_CONTADAS},
        sha256=sha.hexdigest(),
        tamanho=tamanho,
    )


def gravar_meta(dump: Path, resumo: Resumo) -> Path:
    meta = {
        "arquivo": dump.name,
        "criado_em": data_do_nome(dump.name).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tamanho_bytes": resumo.tamanho,
        "sha256": resumo.sha256,
        "versao_mysql": resumo.versao_mysql,
        "alembic_version": resumo.alembic_version,
        "contagens": resumo.contagens,
    }
    destino = caminho_meta(dump)
    temporario = destino.with_name(destino.name + ".parcial")
    temporario.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temporario, destino)
    return destino


# ---------------------------------------------------------------------------
# Envio ao S3
# ---------------------------------------------------------------------------


def conferir_config_envio(ambiente: dict[str, str]) -> str:
    """Devolve o bucket; lança se a configuração for insegura ou incompleta."""
    bucket = (ambiente.get("BACKUP_S3_BUCKET") or "").strip()
    if not bucket:
        raise ErroBackup("BACKUP_S3_BUCKET vazio: configure /etc/softspend/backup.env")
    # Com chave no ambiente o boto3 a usaria no lugar da função IAM da EC2.
    chaves = [k for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN") if ambiente.get(k)]
    if chaves:
        raise ErroBackup(
            f"{', '.join(chaves)} definida(s): o backup usa só a função IAM da EC2, "
            "sem chave de acesso no ambiente"
        )
    return bucket


def criar_cliente_s3(regiao: str | None):
    import boto3  # importado aqui para os testes não dependerem da AWS

    return boto3.client("s3", region_name=regiao or "sa-east-1")


def enviar(dump: Path, destino: str, ambiente: dict[str, str], cliente=None) -> list[str]:
    bucket = conferir_config_envio(ambiente)
    meta = caminho_meta(dump)
    if not meta.is_file():
        raise ErroBackup(f".meta.json não encontrado (rode 'validar' antes): {meta}")
    chave_dump = chave_s3(dump.name, destino)
    chave_meta = chave_dump[: -len(SUFIXO_DUMP)] + SUFIXO_META
    if cliente is None:
        cliente = criar_cliente_s3(ambiente.get("AWS_DEFAULT_REGION") or ambiente.get("AWS_REGION"))

    enviados = []
    for local, chave in ((dump, chave_dump), (meta, chave_meta)):
        cliente.upload_file(str(local), bucket, chave, ExtraArgs={"ServerSideEncryption": "AES256"})
        remoto = cliente.head_object(Bucket=bucket, Key=chave)["ContentLength"]
        tamanho = local.stat().st_size
        if remoto != tamanho:
            raise ErroBackup(f"tamanho no S3 difere do local em s3://{bucket}/{chave}: {remoto} != {tamanho}")
        enviados.append(f"s3://{bucket}/{chave}")
    return enviados


# ---------------------------------------------------------------------------
# Limpeza local
# ---------------------------------------------------------------------------


def limpar(pasta: Path, manter: int = 2) -> list[Path]:
    if manter < 1:
        raise ErroBackup("manter precisa ser pelo menos 1")
    apagados = []
    for dump in dumps_locais(pasta)[:-manter]:
        for arquivo in (dump, caminho_meta(dump)):
            if arquivo.exists():
                arquivo.unlink()
                apagados.append(arquivo)
    return apagados


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="comando", required=True)
    sub.add_parser("nome")
    p = sub.add_parser("espaco")
    p.add_argument("pasta", type=Path)
    p = sub.add_parser("validar")
    p.add_argument("dump", type=Path)
    p = sub.add_parser("enviar")
    p.add_argument("dump", type=Path)
    p.add_argument("--destino", default="diario", choices=DESTINOS)
    p = sub.add_parser("conferir-config")
    p = sub.add_parser("limpar")
    p.add_argument("pasta", type=Path)
    p.add_argument("--manter", type=int, default=2)
    args = parser.parse_args(argv)

    try:
        if args.comando == "nome":
            print(nome_arquivo())
        elif args.comando == "espaco":
            exigido = conferir_espaco(args.pasta)
            print(f"espaço livre ok (exigido {exigido // (1024 * 1024)} MB)")
        elif args.comando == "validar":
            resumo = validar_dump(args.dump)
            meta = gravar_meta(args.dump, resumo)
            print(f"dump válido ({resumo.tamanho} bytes); meta em {meta}: "
                  f"alembic={resumo.alembic_version} contagens={resumo.contagens}")
        elif args.comando == "conferir-config":
            print(f"bucket: {conferir_config_envio(dict(os.environ))}")
        elif args.comando == "enviar":
            for url in enviar(args.dump, args.destino, dict(os.environ)):
                print(f"enviado e conferido: {url}")
        elif args.comando == "limpar":
            for apagado in limpar(args.pasta, args.manter):
                print(f"apagado local: {apagado}")
    except ErroBackup as e:
        print(f"ERRO: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
