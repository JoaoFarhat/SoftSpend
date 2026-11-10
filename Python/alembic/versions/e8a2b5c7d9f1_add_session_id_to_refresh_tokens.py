"""add session_id to refresh_tokens

Revision ID: e8a2b5c7d9f1
Revises: d6f1a9c3b8e4
Create Date: 2026-11-10 00:00:00.000000

O session_id agrupa os refresh tokens de uma mesma sessao (login) e vai no
claim "sid" do access token, para que logout e deteccao de reuso derrubem o
acesso na hora. Linhas antigas recebem o proprio id: cada uma vira uma sessao
isolada, o que preserva o comportamento anterior delas.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e8a2b5c7d9f1'
down_revision: Union[str, None] = 'd6f1a9c3b8e4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'refresh_tokens',
        sa.Column('session_id', sa.String(36), nullable=True),
    )
    op.execute("UPDATE refresh_tokens SET session_id = id WHERE session_id IS NULL")
    op.alter_column(
        'refresh_tokens',
        'session_id',
        existing_type=sa.String(36),
        nullable=False,
    )
    op.create_index(
        'ix_refresh_tokens_session_id',
        'refresh_tokens',
        ['session_id'],
    )


def downgrade() -> None:
    op.drop_index('ix_refresh_tokens_session_id', 'refresh_tokens')
    op.drop_column('refresh_tokens', 'session_id')
