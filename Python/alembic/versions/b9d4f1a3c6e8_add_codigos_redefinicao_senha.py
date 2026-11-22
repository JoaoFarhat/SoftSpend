"""add codigos_redefinicao_senha

Revision ID: b9d4f1a3c6e8
Revises: b8e4d2f6a1c3
Create Date: 2026-11-22 00:00:00.000000

"Esqueci minha senha": um codigo de 6 digitos por usuario (so o HMAC dele),
com validade e contador de tentativas. Excluir o usuario apaga o codigo (FK
com CASCADE). Ver `services/redefinicao_senha_service.py`.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b9d4f1a3c6e8'
down_revision: Union[str, None] = 'b8e4d2f6a1c3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'codigos_redefinicao_senha',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column(
            'user_id',
            sa.String(36),
            sa.ForeignKey('users.id', ondelete='CASCADE'),
            nullable=False,
        ),
        sa.Column('codigo_hash', sa.String(64), nullable=False),
        sa.Column('expires_at', sa.DateTime(), nullable=False),
        sa.Column('tentativas', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint('user_id', name='uix_codigo_redefinicao_user'),
    )


def downgrade() -> None:
    op.drop_table('codigos_redefinicao_senha')
