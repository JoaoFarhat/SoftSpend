"""Testes do ajudante do backup do MySQL (deploy/ec2/backup_mysql.py)."""

import gzip
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

_CAMINHO = Path(__file__).resolve().parents[2] / "deploy" / "ec2" / "backup_mysql.py"
_spec = importlib.util.spec_from_file_location("backup_mysql", _CAMINHO)
bm = importlib.util.module_from_spec(_spec)
sys.modules["backup_mysql"] = bm  # o @dataclass procura o módulo aqui
_spec.loader.exec_module(bm)

AGORA = datetime(2026, 11, 13, 6, 30, 12, tzinfo=timezone.utc)


def _dump_sql(extra_linhas=(), completo=True, tabelas=bm.TABELAS_CONTADAS):
    linhas = [
        "-- MySQL dump 10.13  Distrib 8.0.36, for Linux (x86_64)",
        "--",
        "-- Server version\t8.0.36-0ubuntu0.24.04.1",
        "CREATE TABLE `alembic_version` (",
        ") ENGINE=InnoDB;",
        "INSERT INTO `alembic_version` VALUES ('f2c4e6a8b0d2');",
    ]
    for t in tabelas:
        linhas += [f"CREATE TABLE `{t}` (", ") ENGINE=InnoDB;"]
    linhas += [
        # Texto com "),(" e aspas escapadas não pode contar como linha nova.
        "INSERT INTO `users` VALUES ('u1','Jo\\'ão','a),(b'),('u2','x\\\\','y');",
        "INSERT INTO `ciclos` VALUES (1,'u1','Viagem (SP)',12.50);",
        "INSERT INTO `ciclos` VALUES (2,'u2','R',NULL),(3,'u2','S',1.00);",
        "INSERT INTO `gastos_dia` VALUES (1,1,'café, pão (2x)',9.90);",
        # Bytes aleatórios em hex para o gzip passar de 10 KB.
        "-- preenchimento " + os.urandom(16 * 1024).hex(),
        *extra_linhas,
    ]
    if completo:
        linhas.append("-- Dump completed on 2026-11-13  6:30:15")
    return ("\n".join(linhas) + "\n").encode("utf-8")


def _gravar_dump(pasta: Path, conteudo: bytes, agora=AGORA) -> Path:
    caminho = pasta / bm.nome_arquivo(agora)
    with gzip.open(caminho, "wb") as f:
        f.write(conteudo)
    return caminho


# --- nome do arquivo ---------------------------------------------------------


def test_nome_do_arquivo_em_utc():
    assert bm.nome_arquivo(AGORA) == "softspend-20261113T063012Z.sql.gz"
    brasilia = AGORA.astimezone(timezone(timedelta(hours=-3)))
    assert bm.nome_arquivo(brasilia) == "softspend-20261113T063012Z.sql.gz"


def test_nome_sem_fuso_recusa():
    with pytest.raises(ValueError):
        bm.nome_arquivo(datetime(2026, 11, 13, 6, 30))


def test_chave_s3_por_destino_ano_e_mes():
    nome = bm.nome_arquivo(AGORA)
    assert bm.chave_s3(nome, "diario") == f"diario/2026/11/{nome}"
    assert bm.chave_s3(nome, "pre-migration") == f"pre-migration/2026/11/{nome}"
    with pytest.raises(bm.ErroBackup):
        bm.chave_s3(nome, "outro")
    with pytest.raises(bm.ErroBackup):
        bm.chave_s3("qualquer.sql.gz", "diario")


# --- validação ---------------------------------------------------------------


def test_valida_e_grava_meta(tmp_path):
    dump = _gravar_dump(tmp_path, _dump_sql())
    resumo = bm.validar_dump(dump)
    meta = json.loads(bm.gravar_meta(dump, resumo).read_text(encoding="utf-8"))

    assert meta["arquivo"] == dump.name
    assert meta["criado_em"] == "2026-11-13T06:30:12Z"
    assert meta["versao_mysql"] == "8.0.36-0ubuntu0.24.04.1"
    assert meta["alembic_version"] == "f2c4e6a8b0d2"
    assert meta["contagens"] == {"users": 2, "ciclos": 3, "dias": 0, "gastos_dia": 1}
    assert meta["tamanho_bytes"] == dump.stat().st_size
    assert len(meta["sha256"]) == 64
    assert bm.caminho_meta(dump).name == "softspend-20261113T063012Z.meta.json"


def test_recusa_dump_pequeno(tmp_path):
    dump = tmp_path / bm.nome_arquivo(AGORA)
    with gzip.open(dump, "wb") as f:
        f.write(b"-- Dump completed on 2026-11-13\n")
    assert dump.stat().st_size <= bm.TAMANHO_MINIMO
    with pytest.raises(bm.ErroBackup, match="pequeno demais"):
        bm.validar_dump(dump)


def test_recusa_dump_incompleto(tmp_path):
    dump = _gravar_dump(tmp_path, _dump_sql(completo=False))
    with pytest.raises(bm.ErroBackup, match="incompleto"):
        bm.validar_dump(dump)


def test_recusa_gzip_corrompido(tmp_path):
    dump = _gravar_dump(tmp_path, _dump_sql())
    dados = bytearray(dump.read_bytes())
    meio = len(dados) // 2
    dados[meio:meio + 64] = bytes(64)
    dump.write_bytes(bytes(dados))
    with pytest.raises(bm.ErroBackup, match="gzip corrompido"):
        bm.validar_dump(dump)


def test_recusa_dump_sem_tabela_principal(tmp_path):
    dump = _gravar_dump(tmp_path, _dump_sql(tabelas=("users", "ciclos", "dias")))
    with pytest.raises(bm.ErroBackup, match="gastos_dia"):
        bm.validar_dump(dump)


def test_contar_tuplas_ignora_parenteses_em_texto():
    assert bm.contar_tuplas(b"(1,'a'),(2,'b) ,(c'),(3,'d\\'),(e');") == 3
    assert bm.contar_tuplas(b"(1,POINT(1 2)),(2,NULL);") == 2


# --- espaço livre ------------------------------------------------------------


def test_espaco_exige_duas_vezes_o_ultimo_dump(tmp_path):
    antigo = _gravar_dump(tmp_path, _dump_sql(), AGORA - timedelta(days=1))
    novo = _gravar_dump(tmp_path, _dump_sql() + _dump_sql(), AGORA)
    assert novo.stat().st_size > antigo.stat().st_size
    with pytest.raises(bm.ErroBackup, match="espaço livre insuficiente"):
        bm.conferir_espaco(tmp_path, livre=bm.ESPACO_MINIMO - 1)
    # Com dump grande, exige 2x o último (o mais novo pelo nome).
    os.truncate(novo, 40 * 1024 * 1024)
    assert bm.conferir_espaco(tmp_path, livre=80 * 1024 * 1024) == 80 * 1024 * 1024
    with pytest.raises(bm.ErroBackup):
        bm.conferir_espaco(tmp_path, livre=80 * 1024 * 1024 - 1)


def test_espaco_sem_dump_anterior_usa_minimo(tmp_path):
    assert bm.conferir_espaco(tmp_path, livre=bm.ESPACO_MINIMO) == bm.ESPACO_MINIMO


# --- envio -------------------------------------------------------------------


class ClienteFalso:
    def __init__(self, diferenca=0):
        self.objetos = {}
        self.diferenca = diferenca
        self.extra = []

    def upload_file(self, local, bucket, chave, ExtraArgs=None):
        self.objetos[(bucket, chave)] = Path(local).stat().st_size
        self.extra.append(ExtraArgs)

    def head_object(self, Bucket, Key):
        return {"ContentLength": self.objetos[(Bucket, Key)] + self.diferenca}


def _dump_validado(pasta):
    dump = _gravar_dump(pasta, _dump_sql())
    bm.gravar_meta(dump, bm.validar_dump(dump))
    return dump


@pytest.mark.parametrize("bucket", [None, "", "   "])
def test_recusa_bucket_vazio(tmp_path, bucket):
    dump = _dump_validado(tmp_path)
    ambiente = {} if bucket is None else {"BACKUP_S3_BUCKET": bucket}
    cliente = ClienteFalso()
    with pytest.raises(bm.ErroBackup, match="BACKUP_S3_BUCKET vazio"):
        bm.enviar(dump, "diario", ambiente, cliente=cliente)
    assert cliente.objetos == {}


def test_recusa_chave_de_acesso_no_ambiente(tmp_path):
    dump = _dump_validado(tmp_path)
    ambiente = {"BACKUP_S3_BUCKET": "b", "AWS_ACCESS_KEY_ID": "AKIA..."}
    with pytest.raises(bm.ErroBackup, match="função IAM"):
        bm.enviar(dump, "diario", ambiente, cliente=ClienteFalso())


def test_envia_dump_e_meta_e_confere_tamanho(tmp_path):
    dump = _dump_validado(tmp_path)
    cliente = ClienteFalso()
    urls = bm.enviar(dump, "pre-migration", {"BACKUP_S3_BUCKET": "softspend-backups-x"}, cliente=cliente)
    assert urls == [
        "s3://softspend-backups-x/pre-migration/2026/11/softspend-20261113T063012Z.sql.gz",
        "s3://softspend-backups-x/pre-migration/2026/11/softspend-20261113T063012Z.meta.json",
    ]
    assert all(e == {"ServerSideEncryption": "AES256"} for e in cliente.extra)


def test_tamanho_diferente_no_s3_falha(tmp_path):
    dump = _dump_validado(tmp_path)
    with pytest.raises(bm.ErroBackup, match="tamanho no S3 difere"):
        bm.enviar(dump, "diario", {"BACKUP_S3_BUCKET": "b"}, cliente=ClienteFalso(diferenca=-1))


def test_envio_exige_meta(tmp_path):
    dump = _gravar_dump(tmp_path, _dump_sql())
    with pytest.raises(bm.ErroBackup, match="meta.json"):
        bm.enviar(dump, "diario", {"BACKUP_S3_BUCKET": "b"}, cliente=ClienteFalso())


# --- limpeza local -----------------------------------------------------------


def test_limpar_mantem_os_dois_ultimos(tmp_path):
    dumps = []
    for dias in (3, 2, 1, 0):
        d = _gravar_dump(tmp_path, b"x", AGORA - timedelta(days=dias))
        bm.caminho_meta(d).write_text("{}")
        dumps.append(d)
    (tmp_path / "outro.txt").write_text("fica")

    apagados = bm.limpar(tmp_path, manter=2)

    assert set(apagados) == {dumps[0], dumps[1], bm.caminho_meta(dumps[0]), bm.caminho_meta(dumps[1])}
    restantes = sorted(p.name for p in tmp_path.iterdir())
    assert restantes == sorted([dumps[2].name, dumps[3].name,
                                bm.caminho_meta(dumps[2]).name, bm.caminho_meta(dumps[3]).name,
                                "outro.txt"])


def test_cli_validar_e_bucket_vazio(tmp_path, monkeypatch, capsys):
    dump = _gravar_dump(tmp_path, _dump_sql())
    assert bm.main(["validar", str(dump)]) == 0
    assert bm.caminho_meta(dump).is_file()

    monkeypatch.delenv("BACKUP_S3_BUCKET", raising=False)
    assert bm.main(["enviar", str(dump)]) == 1
    assert "BACKUP_S3_BUCKET vazio" in capsys.readouterr().err


# --- teste mensal de restauração (§8.2) --------------------------------------

_EC2 = Path(__file__).resolve().parents[2] / "deploy" / "ec2"
_SH = (_EC2 / "testar-restauracao.sh").read_text(encoding="utf-8")
_SERVICE = (_EC2 / "softspend-backup-teste.service").read_text(encoding="utf-8")
_TIMER = (_EC2 / "softspend-backup-teste.timer").read_text(encoding="utf-8")


def _meta_restauracao():
    return {
        "arquivo": "softspend-20261113T063012Z.sql.gz",
        "alembic_version": "f2c4e6a8b0d2",
        "contagens": {"users": 2, "ciclos": 3, "dias": 0, "gastos_dia": 1},
    }


def test_banco_de_teste_e_so_o_descartavel():
    assert bm.BANCO_TESTE == "softspend_restore_test"
    assert f"Environment=RESTORE_DB={bm.BANCO_TESTE}" in _SERVICE


def test_comparar_restauracao_passa_com_tudo_igual():
    bm.comparar_restauracao(
        _meta_restauracao(), "f2c4e6a8b0d2",
        {"users": 2, "ciclos": 3, "dias": 0, "gastos_dia": 1},
    )


def test_comparar_restauracao_falha_com_alembic_diferente():
    with pytest.raises(bm.ErroBackup, match="alembic_version"):
        bm.comparar_restauracao(
            _meta_restauracao(), "aaaaaaaaaaaa",
            {"users": 2, "ciclos": 3, "dias": 0, "gastos_dia": 1},
        )


@pytest.mark.parametrize("tabela", ["users", "ciclos", "dias", "gastos_dia"])
def test_comparar_restauracao_falha_com_cada_contagem_diferente(tabela):
    contagens = {"users": 2, "ciclos": 3, "dias": 0, "gastos_dia": 1}
    contagens[tabela] += 1
    with pytest.raises(bm.ErroBackup, match=tabela):
        bm.comparar_restauracao(_meta_restauracao(), "f2c4e6a8b0d2", contagens)


def test_cli_conferir_restauracao(tmp_path, capsys):
    meta = tmp_path / "softspend-20261113T063012Z.meta.json"
    meta.write_text(json.dumps(_meta_restauracao()), encoding="utf-8")
    base = ["conferir-restauracao", str(meta), "--alembic", "f2c4e6a8b0d2",
            "--contagem", "users=2", "--contagem", "ciclos=3",
            "--contagem", "dias=0", "--contagem", "gastos_dia=1"]
    assert bm.main(base) == 0

    errado = base.copy()
    errado[errado.index("--contagem") + 1] = "users=5"
    assert bm.main(errado) == 1
    assert "users" in capsys.readouterr().err


# --- o .sh, lido como texto ---------------------------------------------------


def test_sh_confere_restore_db_antes_do_primeiro_drop():
    checagem = _SH.index('if [ "$RESTORE_DB" != "softspend_restore_test" ]')
    primeiro_drop = _SH.index("DROP DATABASE")
    assert checagem < primeiro_drop


def test_sh_trap_apaga_o_banco_mesmo_com_falha():
    m = re.search(r"trap\s+(\w+)\s+EXIT", _SH)
    assert m, "precisa de um trap EXIT"
    funcao = m.group(1)
    corpo = _SH[_SH.index(f"{funcao}()"):]
    assert "DROP DATABASE" in corpo


def test_sh_todo_drop_create_e_carga_usa_restore_db():
    for linha in _SH.splitlines():
        if "DROP DATABASE" in linha or "CREATE DATABASE" in linha:
            assert '"$RESTORE_DB"' in linha, linha
    carga = [l for l in _SH.splitlines() if "gunzip -c" in l and "mysql" in l]
    assert len(carga) == 1 and '"$RESTORE_DB"' in carga[0]


def test_sh_drop_create_conectam_sem_banco_padrao():
    """`mysql <banco> -e ...` falha com ERROR 1049 se o banco não existe —
    exatamente o caso do teste, que apaga o banco no fim de cada volta.
    Nos comandos de DROP/CREATE o nome fica só dentro do `-e`."""
    for linha in _SH.splitlines():
        if "DROP DATABASE" not in linha and "CREATE DATABASE" not in linha:
            continue
        assert " -e " in linha, linha
        antes_do_e = linha.split(" -e ", 1)[0]
        assert '"$RESTORE_DB"' not in antes_do_e, linha


def test_sh_usa_restore_cnf_e_chama_conferir():
    assert "--defaults-extra-file=$RESTORE_CNF" in _SH
    assert "conferir-restauracao" in _SH
    assert "backup_mysql.py" in _SH


# --- units do systemd, lidas como texto ---------------------------------------


def test_service_e_oneshot_com_onfailure_e_pouca_prioridade():
    assert "Type=oneshot" in _SERVICE
    assert "OnFailure=softspend-alerta@%n.service" in _SERVICE
    assert "EnvironmentFile=/etc/softspend/backup.env" in _SERVICE
    assert "Nice=10" in _SERVICE
    assert "IOSchedulingClass=best-effort" in _SERVICE
    assert "IOSchedulingPriority=7" in _SERVICE
    assert "testar-restauracao.sh" in _SERVICE


def test_timer_e_mensal_e_persistent():
    assert re.search(r"^OnCalendar=\*-\*-01 ", _TIMER, re.MULTILINE)
    assert "Persistent=true" in _TIMER
    assert "Unit=softspend-backup-teste.service" in _TIMER


# --- download do dump mais novo (fallback do .sh) -----------------------------


class ClienteS3Falso:
    def __init__(self, objetos):
        self.objetos = objetos
        self.baixados = []

    def list_objects_v2(self, Bucket, Prefix, **kwargs):
        return {
            "Contents": [{"Key": k} for k in sorted(self.objetos)
                         if k.startswith(Prefix)]
        }

    def download_file(self, bucket, chave, destino):
        self.baixados.append(chave)
        Path(destino).write_bytes(self.objetos[chave])


def test_baixar_mais_recente_pega_o_mais_novo_com_meta(tmp_path):
    objetos = {
        "diario/2026/10/softspend-20261031T063000Z.sql.gz": b"velho",
        "diario/2026/10/softspend-20261031T063000Z.meta.json": b"{}",
        "diario/2026/11/softspend-20261113T063012Z.sql.gz": b"novo",
        "diario/2026/11/softspend-20261113T063012Z.meta.json": b"{}",
        "diario/2026/11/nao-e-dump.txt": b"x",
    }
    cliente = ClienteS3Falso(objetos)
    dump = bm.baixar_mais_recente(
        tmp_path / "dl", {"BACKUP_S3_BUCKET": "b"}, cliente=cliente)
    assert dump.name == "softspend-20261113T063012Z.sql.gz"
    assert dump.read_bytes() == b"novo"
    assert bm.caminho_meta(dump).is_file()
    assert cliente.baixados == [
        "diario/2026/11/softspend-20261113T063012Z.sql.gz",
        "diario/2026/11/softspend-20261113T063012Z.meta.json",
    ]


def test_baixar_mais_recente_sem_dump_falha(tmp_path):
    with pytest.raises(bm.ErroBackup, match="nenhum dump"):
        bm.baixar_mais_recente(
            tmp_path, {"BACKUP_S3_BUCKET": "b"}, cliente=ClienteS3Falso({}))
