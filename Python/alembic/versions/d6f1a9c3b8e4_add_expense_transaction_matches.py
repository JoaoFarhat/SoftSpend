"""add expense transaction matches

Revision ID: d6f1a9c3b8e4
Revises: c4d8f2a6b9e0
Create Date: 2026-10-15 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'd6f1a9c3b8e4'
down_revision: Union[str, None] = 'c4d8f2a6b9e0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'expense_transaction_matches',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column(
            'gasto_id',
            sa.Integer(),
            sa.ForeignKey('gastos_dia.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column(
            'cartao_transacao_id',
            sa.Integer(),
            sa.ForeignKey('credit_card_transactions.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('status', sa.String(30), nullable=False),
        sa.Column('score', sa.Integer(), nullable=False),
        sa.Column('method', sa.String(50), nullable=False),
        sa.Column('confirmed_by_user', sa.Boolean(), nullable=False),
        sa.Column('matched_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('gasto_id', name='uix_expense_match_gasto'),
        sa.UniqueConstraint(
            'cartao_transacao_id', name='uix_expense_match_transaction'
        ),
    )
    op.create_index(
        'ix_expense_transaction_matches_status',
        'expense_transaction_matches',
        ['status'],
    )


def downgrade() -> None:
    op.drop_index(
        'ix_expense_transaction_matches_status',
        'expense_transaction_matches',
    )
    op.drop_table('expense_transaction_matches')
