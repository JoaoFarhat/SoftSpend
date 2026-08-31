"""add refresh tokens table

Revision ID: 97ea189fc3da
Revises: 335cdb5f77dd
Create Date: 2026-08-31 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '97ea189fc3da'
down_revision: Union[str, None] = '335cdb5f77dd'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'refresh_tokens',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('token_hash', sa.String(64), unique=True, nullable=False),
        sa.Column('expires_at', sa.DateTime, nullable=False),
        sa.Column('revoked_at', sa.DateTime, nullable=True),
        sa.Column('created_at', sa.DateTime, nullable=False),
    )
    op.create_index(
        'ix_refresh_tokens_user_id_created_at',
        'refresh_tokens',
        ['user_id', 'created_at'],
    )


def downgrade() -> None:
    op.drop_index('ix_refresh_tokens_user_id_created_at', 'refresh_tokens')
    op.drop_table('refresh_tokens')
