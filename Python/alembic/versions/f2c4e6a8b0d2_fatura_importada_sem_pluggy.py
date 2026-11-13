"""fatura importada sem pluggy: conexao_id opcional e origem nos cartões

Revision ID: f2c4e6a8b0d2
Revises: e8a2b5c7d9f1
Create Date: 2026-11-13 00:00:00.000000

A fatura importada por arquivo (spec docs/cartao-sem-open-finance.md §2.6)
reusa as tabelas do Open Finance sem conexão Pluggy:

- credit_card_accounts.conexao_id passa a aceitar NULL;
- coluna nova credit_card_accounts.origem ('PLUGGY' ou 'FATURA'), com
  'PLUGGY' nas linhas existentes.

O downgrade apaga as linhas origem = 'FATURA' (com filhas em bills,
transactions e matches), remove a coluna e devolve conexao_id a NOT NULL.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'f2c4e6a8b0d2'
down_revision: Union[str, None] = 'e8a2b5c7d9f1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_ORIGEM_FATURA = "'FATURA'"


def upgrade() -> None:
    if op.get_bind().dialect.name == "sqlite":
        # SQLite não tem ALTER COLUMN: o modo batch recria a tabela.
        with op.batch_alter_table('credit_card_accounts') as batch:
            batch.alter_column(
                'conexao_id', existing_type=sa.Integer(), nullable=True
            )
            batch.add_column(
                sa.Column(
                    'origem',
                    sa.String(20),
                    server_default='PLUGGY',
                    nullable=False,
                )
            )
    else:
        op.alter_column(
            'credit_card_accounts',
            'conexao_id',
            existing_type=sa.Integer(),
            nullable=True,
        )
        op.add_column(
            'credit_card_accounts',
            sa.Column(
                'origem',
                sa.String(20),
                server_default='PLUGGY',
                nullable=False,
            ),
        )


def downgrade() -> None:
    # Remove primeiro as filhas das contas importadas (o IN portátil vale
    # tanto para MySQL quanto para SQLite, sem depender de ON DELETE).
    op.execute(
        "DELETE FROM expense_transaction_matches WHERE cartao_transacao_id IN "
        "(SELECT id FROM credit_card_transactions WHERE cartao_id IN "
        f"(SELECT id FROM credit_card_accounts WHERE origem = {_ORIGEM_FATURA}))"
    )
    op.execute(
        "DELETE FROM credit_card_transactions WHERE cartao_id IN "
        f"(SELECT id FROM credit_card_accounts WHERE origem = {_ORIGEM_FATURA})"
    )
    op.execute(
        "DELETE FROM credit_card_bills WHERE cartao_id IN "
        f"(SELECT id FROM credit_card_accounts WHERE origem = {_ORIGEM_FATURA})"
    )
    op.execute(
        f"DELETE FROM credit_card_accounts WHERE origem = {_ORIGEM_FATURA}"
    )

    if op.get_bind().dialect.name == "sqlite":
        with op.batch_alter_table('credit_card_accounts') as batch:
            batch.drop_column('origem')
            batch.alter_column(
                'conexao_id', existing_type=sa.Integer(), nullable=False
            )
    else:
        op.drop_column('credit_card_accounts', 'origem')
        op.alter_column(
            'credit_card_accounts',
            'conexao_id',
            existing_type=sa.Integer(),
            nullable=False,
        )
