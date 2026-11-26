#!/bin/bash
# Teste mensal de restauração do backup (docs/backup-mysql.md, §8.2).
#
# Uso:
#   sudo bash testar-restauracao.sh
#
# Roda como root (pelo softspend-backup-teste.service), porque a senha do
# usuário softspend_restore fica em /etc/softspend/restore.cnf (root, modo
# 600). Restaura o dump mais novo num banco descartável e compara com o
# .meta.json; qualquer falha sai com código diferente de zero e dispara o
# alerta por e-mail (OnFailure da unidade).
set -euo pipefail
umask 077

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rodando à mão (fora do systemd), carrega o mesmo arquivo de ambiente do
# backup (de onde vem o BACKUP_S3_BUCKET para o download de emergência).
BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-/etc/softspend/backup.env}"
if [ -z "${SOFTSPEND_BACKUP_ENV_CARREGADO:-}" ] && [ -f "$BACKUP_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$BACKUP_ENV_FILE"
    set +a
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/softspend}"
RESTORE_CNF="${RESTORE_CNF:-/etc/softspend/restore.cnf}"
BACKUP_PYTHON="${BACKUP_PYTHON:-/home/ubuntu/SoftSpend/Python/.venv/bin/python}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/softspend/backup.log}"
RESTORE_DB="${RESTORE_DB:-softspend_restore_test}"

# Trava de segurança: o teste derruba e recria o banco de destino. Antes de
# qualquer comando no MySQL, o script só aceita o nome descartável — um
# RESTORE_DB errado (ou vazio) sai 1 aqui, nunca depois do primeiro DROP.
if [ "$RESTORE_DB" != "softspend_restore_test" ]; then
    echo "ERRO: RESTORE_DB precisa ser exatamente 'softspend_restore_test' (recebido: '$RESTORE_DB')" >&2
    exit 1
fi

log() {
    local linha
    linha="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [teste-restauracao] $*"
    echo "$linha"
    if [ -n "$BACKUP_LOG" ]; then
        echo "$linha" >> "$BACKUP_LOG" 2>/dev/null || true
    fi
}

ETAPA="início"
BANCO_CRIADO=0
TMPDIR_TESTE=""
ao_sair() {
    local codigo=$?
    # Apaga o banco de teste mesmo com falha (e mesmo no sucesso): ele só
    # existe para esta conferência.
    if [ "$BANCO_CRIADO" -eq 1 ]; then
        mysql "--defaults-extra-file=$RESTORE_CNF" -e "DROP DATABASE IF EXISTS "$RESTORE_DB"" || true
    fi
    if [ -n "$TMPDIR_TESTE" ] && [ -d "$TMPDIR_TESTE" ]; then
        rm -rf "$TMPDIR_TESTE"
    fi
    if [ "$codigo" -ne 0 ]; then
        log "FALHOU na etapa '$ETAPA' (código $codigo). Detalhes: journalctl -u softspend-backup-teste"
    fi
}
trap ao_sair EXIT

ajudante() {
    "$BACKUP_PYTHON" "$DIR_SCRIPT/backup_mysql.py" "$@"
}

INICIO=$(date +%s)
log "começando"

ETAPA="configuração"
[ -x "$BACKUP_PYTHON" ] || { log "ERRO: python não encontrado em $BACKUP_PYTHON"; exit 1; }
command -v mysql >/dev/null || { log "ERRO: cliente mysql não instalado"; exit 1; }
command -v gunzip >/dev/null || { log "ERRO: gunzip não instalado"; exit 1; }
[ -r "$RESTORE_CNF" ] || { log "ERRO: não consigo ler $RESTORE_CNF"; exit 1; }

ETAPA="escolha do dump"
ultimo="$(ls -1 "$BACKUP_DIR" 2>/dev/null \
    | grep -E '^softspend-[0-9]{8}T[0-9]{6}Z\.sql\.gz$' | sort | tail -n 1 || true)"
DUMP=""
if [ -n "$ultimo" ]; then
    DUMP="$BACKUP_DIR/$ultimo"
else
    # Sem dump local (limpeza ou servidor novo): baixa o mais novo do S3.
    TMPDIR_TESTE="$(mktemp -d)"
    DUMP="$(ajudante baixar-mais-novo "$TMPDIR_TESTE")"
    log "sem dump local; baixado de s3://${BACKUP_S3_BUCKET:-?}/diario/"
fi
META="${DUMP%.sql.gz}.meta.json"
[ -f "$META" ] || { log "ERRO: .meta.json não encontrado ao lado de $DUMP"; exit 1; }
log "dump escolhido: $(basename "$DUMP") ($(stat -c %s "$DUMP") bytes)"

ETAPA="restauração"
# DROP/CREATE conectam sem banco padrão: o banco de teste pode não existir
# (mysql com banco padrão falharia com ERROR 1049 antes de rodar o SQL).
# O nome vai só dentro do -e; a carga e as consultas usam o banco como padrão.
mysql "--defaults-extra-file=$RESTORE_CNF" -e "DROP DATABASE IF EXISTS "$RESTORE_DB""
mysql "--defaults-extra-file=$RESTORE_CNF" -e "CREATE DATABASE "$RESTORE_DB""
BANCO_CRIADO=1
gunzip -c "$DUMP" | mysql "--defaults-extra-file=$RESTORE_CNF" "$RESTORE_DB"

ETAPA="conferência"
# -N -B: saída crua (uma coluna por linha), só números e a versão — nunca dado.
ALEMBIC="$(mysql "--defaults-extra-file=$RESTORE_CNF" "$RESTORE_DB" \
    -N -B -e "SELECT version_num FROM alembic_version" | paste -sd, -)"
CONTAGENS=()
for tabela in users ciclos dias gastos_dia; do
    n="$(mysql "--defaults-extra-file=$RESTORE_CNF" "$RESTORE_DB" \
        -N -B -e "SELECT COUNT(*) FROM $tabela")"
    CONTAGENS+=(--contagem "$tabela=$n")
done
saida="$(ajudante conferir-restauracao "$META" --alembic "$ALEMBIC" "${CONTAGENS[@]}" 2>&1)" || {
    log "restauração NÃO confere: $saida"
    exit 1
}

ETAPA="fim"
log "$saida; tempo total: $(( $(date +%s) - INICIO ))s"
