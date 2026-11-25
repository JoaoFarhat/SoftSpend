"""data do dia: coluna dias.data_dia (data de calendario) + backfill

Revision ID: b8e4d2f6a1c3
Revises: a7c3e9f1b5d2
Create Date: 2026-11-25 00:00:00.000000

Spec `docs/data-do-dia.md` §4: o dia da viagem passa a ser uma data de
calendário (`YYYY-MM-DD`), sem hora nem fuso. `dias.data` (o instante UTC da
meia-noite local do aparelho) continua gravado como está — só ordenação de
compatibilidade e resposta para apps antigos.

O backfill recupera o dia pela hora UTC do instante: o app sempre gravou
meia-noite no fuso local, então hora ≥ 11 UTC é fuso a leste de Greenwich e
o dia certo é o dia UTC seguinte; abaixo disso é o próprio dia UTC.

A coluna fica anulável (linha nova sempre preenche; o fallback de
`data_do_dia` cobre o resto) — sem NOT NULL para não travar deploy. O
downgrade só derruba índice e coluna: `data` segue intacta.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b8e4d2f6a1c3'
down_revision: Union[str, None] = 'a7c3e9f1b5d2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_IX_NOME = 'ix_dia_ciclo_data_dia'


def upgrade() -> None:
    if op.get_bind().dialect.name == "sqlite":
        with op.batch_alter_table('dias') as batch:
            batch.add_column(sa.Column('data_dia', sa.Date(), nullable=True))
        # SQLite guarda o DateTime como texto "YYYY-MM-DD HH:MM:SS".
        op.execute(
            "UPDATE dias SET data_dia = CASE "
            "WHEN CAST(strftime('%H', data) AS INTEGER) >= 11 "
            "THEN date(data, '+1 day') ELSE date(data) END "
            "WHERE data IS NOT NULL"
        )
        op.create_index(_IX_NOME, 'dias', ['ciclo_id', 'data_dia'])
    else:
        op.add_column('dias', sa.Column('data_dia', sa.Date(), nullable=True))
        op.execute(
            "UPDATE dias SET data_dia = IF(HOUR(data) >= 11, "
            "DATE(data) + INTERVAL 1 DAY, DATE(data)) "
            "WHERE data IS NOT NULL"
        )
        op.create_index(_IX_NOME, 'dias', ['ciclo_id', 'data_dia'])


def downgrade() -> None:
    if op.get_bind().dialect.name == "sqlite":
        op.drop_index(_IX_NOME, table_name='dias')
        with op.batch_alter_table('dias') as batch:
            batch.drop_column('data_dia')
    else:
        op.drop_index(_IX_NOME, table_name='dias')
        op.drop_column('dias', 'data_dia')
