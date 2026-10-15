"""add open finance tables

Revision ID: c4d8f2a6b9e0
Revises: 97ea189fc3da
Create Date: 2026-10-15 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c4d8f2a6b9e0'
down_revision: Union[str, None] = '97ea189fc3da'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'open_finance_connections',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('provider', sa.String(30), nullable=False),
        sa.Column('item_id', sa.String(64), nullable=False),
        sa.Column('client_user_id', sa.String(100), nullable=True),
        sa.Column('institution_name', sa.String(255), nullable=True),
        sa.Column('status', sa.String(50), nullable=True),
        sa.Column('error_code', sa.String(100), nullable=True),
        sa.Column('error_message', sa.String(500), nullable=True),
        sa.Column('last_sync_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint(
            'provider', 'item_id', name='uix_open_finance_provider_item'
        ),
    )
    op.create_index(
        'ix_open_finance_connections_user_id',
        'open_finance_connections',
        ['user_id'],
    )

    op.create_table(
        'credit_card_accounts',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column(
            'conexao_id',
            sa.Integer(),
            sa.ForeignKey('open_finance_connections.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('account_id', sa.String(64), nullable=False, unique=True),
        sa.Column('institution_name', sa.String(255), nullable=True),
        sa.Column('name', sa.String(255), nullable=True),
        sa.Column('marketing_name', sa.String(255), nullable=True),
        sa.Column('number_last4', sa.String(4), nullable=True),
        sa.Column('type', sa.String(30), nullable=True),
        sa.Column('subtype', sa.String(30), nullable=True),
        sa.Column('currency_code', sa.String(3), nullable=True),
        sa.Column('balance', sa.Numeric(14, 2), nullable=True),
        sa.Column('credit_limit', sa.Numeric(14, 2), nullable=True),
        sa.Column('available_credit_limit', sa.Numeric(14, 2), nullable=True),
        sa.Column('minimum_payment', sa.Numeric(14, 2), nullable=True),
        sa.Column('balance_close_date', sa.DateTime(timezone=True), nullable=True),
        sa.Column('balance_due_date', sa.DateTime(timezone=True), nullable=True),
        sa.Column('brand', sa.String(50), nullable=True),
        sa.Column('level', sa.String(50), nullable=True),
        sa.Column('status', sa.String(50), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        'ix_credit_card_accounts_user_id', 'credit_card_accounts', ['user_id']
    )
    op.create_index(
        'ix_credit_card_accounts_conexao_id',
        'credit_card_accounts',
        ['conexao_id'],
    )

    op.create_table(
        'credit_card_bills',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column(
            'cartao_id',
            sa.Integer(),
            sa.ForeignKey('credit_card_accounts.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('bill_id', sa.String(64), nullable=False, unique=True),
        sa.Column('due_date', sa.DateTime(timezone=True), nullable=True),
        sa.Column('closing_date', sa.DateTime(timezone=True), nullable=True),
        sa.Column('total_amount', sa.Numeric(14, 2), nullable=True),
        sa.Column('currency_code', sa.String(3), nullable=True),
        sa.Column('minimum_payment_amount', sa.Numeric(14, 2), nullable=True),
        sa.Column('allows_installments', sa.Boolean(), nullable=True),
        sa.Column('finance_charges', sa.JSON(), nullable=True),
        sa.Column('payments', sa.JSON(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        'ix_credit_card_bills_user_id', 'credit_card_bills', ['user_id']
    )
    op.create_index(
        'ix_credit_card_bills_cartao_id', 'credit_card_bills', ['cartao_id']
    )

    op.create_table(
        'credit_card_transactions',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column(
            'cartao_id',
            sa.Integer(),
            sa.ForeignKey('credit_card_accounts.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column(
            'fatura_id',
            sa.Integer(),
            sa.ForeignKey('credit_card_bills.id', ondelete='SET NULL'),
            nullable=True,
        ),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('transaction_id', sa.String(64), nullable=False, unique=True),
        sa.Column('description', sa.String(255), nullable=True),
        sa.Column('description_raw', sa.String(500), nullable=True),
        sa.Column('amount', sa.Numeric(14, 2), nullable=True),
        sa.Column('amount_in_account_currency', sa.Numeric(14, 2), nullable=True),
        sa.Column('currency_code', sa.String(3), nullable=True),
        sa.Column('date', sa.DateTime(timezone=True), nullable=True),
        sa.Column('category', sa.String(100), nullable=True),
        sa.Column('status', sa.String(30), nullable=True),
        sa.Column('type', sa.String(30), nullable=True),
        sa.Column('provider_code', sa.String(100), nullable=True),
        sa.Column('provider_id', sa.String(100), nullable=True),
        sa.Column('merchant_name', sa.String(255), nullable=True),
        sa.Column('credit_card_metadata', sa.JSON(), nullable=True),
        sa.Column('last_seen_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        'ix_credit_card_transactions_user_id',
        'credit_card_transactions',
        ['user_id'],
    )
    op.create_index(
        'ix_credit_card_transactions_cartao_id',
        'credit_card_transactions',
        ['cartao_id'],
    )
    op.create_index(
        'ix_credit_card_transactions_user_date',
        'credit_card_transactions',
        ['user_id', 'date'],
    )


def downgrade() -> None:
    op.drop_index(
        'ix_credit_card_transactions_user_date', 'credit_card_transactions'
    )
    op.drop_index(
        'ix_credit_card_transactions_cartao_id', 'credit_card_transactions'
    )
    op.drop_index(
        'ix_credit_card_transactions_user_id', 'credit_card_transactions'
    )
    op.drop_table('credit_card_transactions')

    op.drop_index('ix_credit_card_bills_cartao_id', 'credit_card_bills')
    op.drop_index('ix_credit_card_bills_user_id', 'credit_card_bills')
    op.drop_table('credit_card_bills')

    op.drop_index(
        'ix_credit_card_accounts_conexao_id', 'credit_card_accounts'
    )
    op.drop_index('ix_credit_card_accounts_user_id', 'credit_card_accounts')
    op.drop_table('credit_card_accounts')

    op.drop_index(
        'ix_open_finance_connections_user_id', 'open_finance_connections'
    )
    op.drop_table('open_finance_connections')
