"""add assinaturas e apple_notificacoes

Revision ID: a7c3e9f1b5d2
Revises: f2c4e6a8b0d2
Create Date: 2026-11-13 00:00:00.000000

Assinatura AS1 (`docs/publicacao.md` §1.4): uma linha por usuário em
`assinaturas`, com o `app_account_token` gerado no servidor, e o registro das
notificações da App Store em `apple_notificacoes` (usado a partir da AS2).
Excluir o usuário apaga a assinatura (FK com CASCADE).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a7c3e9f1b5d2'
down_revision: Union[str, None] = 'f2c4e6a8b0d2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'assinaturas',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('app_account_token', sa.String(36), nullable=False),
        sa.Column('original_transaction_id', sa.String(64), nullable=True),
        sa.Column('produto', sa.String(100), nullable=True),
        sa.Column('ambiente', sa.String(20), nullable=True),
        sa.Column(
            'status', sa.String(20), nullable=False, server_default='none'
        ),
        sa.Column('expira_em', sa.DateTime(), nullable=True),
        sa.Column('carencia_ate', sa.DateTime(), nullable=True),
        sa.Column('renovacao_automatica', sa.Boolean(), nullable=True),
        sa.Column('atualizado_em', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('user_id', name='uix_assinatura_user_id'),
        sa.UniqueConstraint(
            'app_account_token', name='uix_assinatura_app_account_token'
        ),
        sa.UniqueConstraint(
            'original_transaction_id',
            name='uix_assinatura_original_transaction_id',
        ),
    )
    op.create_table(
        'apple_notificacoes',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('notification_uuid', sa.String(36), nullable=False),
        sa.Column('tipo', sa.String(50), nullable=False),
        sa.Column('subtipo', sa.String(50), nullable=True),
        sa.Column('original_transaction_id', sa.String(64), nullable=True),
        sa.Column('recebida_em', sa.DateTime(), nullable=False),
        sa.UniqueConstraint(
            'notification_uuid', name='uix_apple_notificacao_uuid'
        ),
    )
    op.create_index(
        'ix_apple_notificacoes_original_transaction_id',
        'apple_notificacoes',
        ['original_transaction_id'],
    )


def downgrade() -> None:
    op.drop_index(
        'ix_apple_notificacoes_original_transaction_id', 'apple_notificacoes'
    )
    op.drop_table('apple_notificacoes')
    op.drop_table('assinaturas')
