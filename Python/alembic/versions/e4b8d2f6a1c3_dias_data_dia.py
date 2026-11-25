"""dias.data_dia: o dia da viagem como data de calendário

Revision ID: e4b8d2f6a1c3
Revises: a7c3e9f1b5d2
Create Date: 2026-11-25 00:00:00.000000

Spec `docs/data-do-dia.md` (tarefa D1). `dias.data` guarda a meia-noite local
do aparelho como instante UTC, e ler `.date()` em UTC erra um dia nos fusos
a leste de Greenwich. A coluna nova `dias.data_dia` (`DATE`, anulável) guarda
o dia de calendário: o app novo o manda em `data_local`; para o app antigo e
para as linhas já gravadas vale a heurística do §4 —

- hora UTC >= 11 → aparelho a leste de Greenwich: o dia certo é o dia UTC + 1;
- hora UTC < 11 → mesmo dia UTC.

A coluna fica anulável (linha nova sempre preenche; o fallback do servidor
cobre o resto) e o índice composto `(ciclo_id, data_dia)` acompanha as
leituras agrupadas por viagem. O downgrade só derruba índice e coluna:
`dias.data` segue intacta.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e4b8d2f6a1c3'
down_revision: Union[str, None] = 'a7c3e9f1b5d2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('dias', sa.Column('data_dia', sa.Date(), nullable=True))

    if op.get_bind().dialect.name == 'mysql':
        # `data` é gravada em UTC sem fuso; `DATE`/`HOUR` operam nesse valor.
        op.execute(
            "UPDATE dias SET data_dia = "
            "IF(HOUR(data) >= 11, DATE(data) + INTERVAL 1 DAY, DATE(data)) "
            "WHERE data IS NOT NULL"
        )
    else:
        # SQLite (testes): `data` é o texto UTC; `date()`/`strftime` o leem.
        op.execute(
            "UPDATE dias SET data_dia = CASE "
            "WHEN CAST(strftime('%H', data) AS INTEGER) >= 11 "
            "THEN date(data, '+1 day') ELSE date(data) END "
            "WHERE data IS NOT NULL"
        )

    op.create_index(
        'ix_dias_ciclo_data_dia', 'dias', ['ciclo_id', 'data_dia']
    )


def downgrade() -> None:
    # `batch_alter_table` também no MySQL: no SQLite ele recria a tabela sem
    # a coluna, preservando `dias.data` e o resto.
    with op.batch_alter_table('dias') as batch:
        batch.drop_index('ix_dias_ciclo_data_dia')
        batch.drop_column('data_dia')
