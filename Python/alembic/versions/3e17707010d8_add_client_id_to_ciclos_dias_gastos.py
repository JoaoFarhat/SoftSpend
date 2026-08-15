"""add client_id to ciclos dias and gastos

Revision ID: 3e17707010d8
Revises: a1f4c9b2d7e3
Create Date: 2026-08-14 21:39:50.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '3e17707010d8'
down_revision: Union[str, None] = 'a1f4c9b2d7e3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('ciclos', sa.Column('client_id', sa.String(50), nullable=True))
    op.create_index('ix_ciclos_client_id', 'ciclos', ['client_id'])
    op.create_unique_constraint('uix_ciclo_client_id_usuario', 'ciclos', ['client_id', 'id_usuario'])

    op.add_column('dias', sa.Column('client_id', sa.String(50), nullable=True))
    op.create_index('ix_dias_client_id', 'dias', ['client_id'])
    op.create_unique_constraint('uix_dia_client_id_ciclo', 'dias', ['client_id', 'ciclo_id'])

    op.add_column('gastos_dia', sa.Column('client_id', sa.String(50), nullable=True))
    op.create_index('ix_gastos_dia_client_id', 'gastos_dia', ['client_id'])
    op.create_unique_constraint('uix_gasto_client_id_dia', 'gastos_dia', ['client_id', 'dia_id'])


def downgrade() -> None:
    op.drop_constraint('uix_gasto_client_id_dia', 'gastos_dia')
    op.drop_index('ix_gastos_dia_client_id', 'gastos_dia')
    op.drop_column('gastos_dia', 'client_id')

    op.drop_constraint('uix_dia_client_id_ciclo', 'dias')
    op.drop_index('ix_dias_client_id', 'dias')
    op.drop_column('dias', 'client_id')

    op.drop_constraint('uix_ciclo_client_id_usuario', 'ciclos')
    op.drop_index('ix_ciclos_client_id', 'ciclos')
    op.drop_column('ciclos', 'client_id')
