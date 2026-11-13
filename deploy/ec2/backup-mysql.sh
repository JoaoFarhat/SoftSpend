#!/bin/bash
# Backup do MySQL da EC2 (docs/backup-mysql.md, §3).
#
# Uso:
#   sudo backup-mysql.sh                  # dump diário -> s3://<bucket>/diario/AAAA/MM/
#   sudo backup-mysql.sh --destino pre-migration
#   sudo backup-mysql.sh --dry-run        # só faz o dump e a validação, sem enviar
#
# Roda como root (pelo softspend-backup.service), porque a senha do usuário
# softspend_backup fica em /etc/softspend/backup.cnf (root, modo 600).
# Configuração em /etc/softspend/backup.env (modelo: backup.env.example).
# Qualquer falha sai com código diferente de zero.
set -euo pipefail
umask 077

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rodando à mão (fora do systemd), carrega o mesmo arquivo de ambiente.
# Nunca carrega o .env da API: as chaves S3_* de lá são do bucket dos comprovantes.
BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-/etc/softspend/backup.env}"
if [ -z "${SOFTSPEND_BACKUP_ENV_CARREGADO:-}" ] && [ -f "$BACKUP_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$BACKUP_ENV_FILE"
    set +a
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/softspend}"
BACKUP_MYSQL_CNF="${BACKUP_MYSQL_CNF:-/etc/softspend/backup.cnf}"
BACKUP_MYSQL_DATABASE="${BACKUP_MYSQL_DATABASE:-softspend}"
BACKUP_PYTHON="${BACKUP_PYTHON:-/home/ubuntu/SoftSpend/Python/.venv/bin/python}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/softspend/backup.log}"
BACKUP_MANTER_LOCAL="${BACKUP_MANTER_LOCAL:-2}"

DESTINO=diario
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --destino) DESTINO="${2:-}"; shift ;;
        --destino=*) DESTINO="${1#--destino=}" ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "ERRO: argumento desconhecido: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$DESTINO" in
    diario|pre-migration) ;;
    *) echo "ERRO: destino inválido: '$DESTINO' (use diario ou pre-migration)" >&2; exit 2 ;;
esac

log() {
    local linha
    linha="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [backup] $*"
    echo "$linha"
    if [ -n "$BACKUP_LOG" ]; then
        echo "$linha" >> "$BACKUP_LOG" 2>/dev/null || true
    fi
}

ETAPA="início"
PARCIAL=""
ao_sair() {
    local codigo=$?
    if [ -n "$PARCIAL" ] && [ -f "$PARCIAL" ]; then
        rm -f "$PARCIAL"
    fi
    if [ "$codigo" -ne 0 ]; then
        log "FALHOU na etapa '$ETAPA' (código $codigo). Detalhes: journalctl -u softspend-backup"
    fi
}
trap ao_sair EXIT

ajudante() {
    "$BACKUP_PYTHON" "$DIR_SCRIPT/backup_mysql.py" "$@"
}

# Roda o ajudante e copia a saída (inclusive os erros) para o log.
passo() {
    ajudante "$@" 2>&1 | while IFS= read -r l; do log "$l"; done
}

modo="envio para $DESTINO/"
[ "$DRY_RUN" -eq 1 ] && modo="dry-run, sem envio"
log "começando ($modo)"

ETAPA="configuração"
[ -x "$BACKUP_PYTHON" ] || { log "ERRO: python não encontrado em $BACKUP_PYTHON"; exit 1; }
command -v mysqldump >/dev/null || { log "ERRO: mysqldump não instalado"; exit 1; }
[ -r "$BACKUP_MYSQL_CNF" ] || { log "ERRO: não consigo ler $BACKUP_MYSQL_CNF"; exit 1; }
if [ "$DRY_RUN" -eq 0 ]; then
    passo conferir-config
fi
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

ETAPA="espaço livre"
passo espaco "$BACKUP_DIR"

ETAPA="dump"
NOME="$(ajudante nome)"
DUMP="$BACKUP_DIR/$NOME"
PARCIAL="$DUMP.parcial"

FLAGS=(--single-transaction --quick --routines --triggers --no-tablespaces
       --default-character-set=utf8mb4)
# --set-gtid-purged só existe no mysqldump do MySQL (não no do MariaDB).
# grep sem -q lê tudo: com -q o mysqldump tomaria SIGPIPE e o pipefail daria falso.
if mysqldump --help 2>/dev/null | grep -- '--set-gtid-purged' >/dev/null; then
    FLAGS+=(--set-gtid-purged=OFF)
fi

# --defaults-extra-file precisa ser o primeiro argumento; a senha nunca
# aparece na linha de comando (nem no `ps`).
mysqldump --defaults-extra-file="$BACKUP_MYSQL_CNF" "${FLAGS[@]}" "$BACKUP_MYSQL_DATABASE" \
    | gzip -c > "$PARCIAL"
gzip -t "$PARCIAL"
mv "$PARCIAL" "$DUMP"
# Até passar na validação, o trap apaga o dump: um arquivo inválido com nome
# de dump contaria como "um dos 2 últimos" na limpeza e no cálculo de espaço.
PARCIAL="$DUMP"
log "dump gravado: $DUMP ($(stat -c %s "$DUMP") bytes)"

ETAPA="validação"
passo validar "$DUMP"
PARCIAL=""

if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: nada foi enviado; arquivo mantido em $DUMP"
    exit 0
fi

ETAPA="envio ao S3"
passo enviar --destino "$DESTINO" "$DUMP"

ETAPA="limpeza local"
passo limpar --manter "$BACKUP_MANTER_LOCAL" "$BACKUP_DIR"

ETAPA="fim"
log "backup concluído: $NOME"
