"""Add comprovante_key to gasto

Revision ID: a1f4c9b2d7e3
Revises: 663d2dcc98c8
Create Date: 2026-08-12 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = 'a1f4c9b2d7e3'
down_revision: Union[str, Sequence[str], None] = '663d2dcc98c8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column('gastos_dia', sa.Column('comprovante_key', sa.String(length=255), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('gastos_dia', 'comprovante_key')
