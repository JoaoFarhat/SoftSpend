"""use decimal for monetary values

Revision ID: 335cdb5f77dd
Revises: b2c4d6e8f0a1
Create Date: 2026-08-26 00:00:00.000000

Converte colunas monetárias de FLOAT para DECIMAL(10, 2) para evitar
problemas de arredondamento em cálculos financeiros.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = '335cdb5f77dd'
down_revision: Union[str, None] = 'b2c4d6e8f0a1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Ciclos
    op.alter_column(
        'ciclos', 'valor_total',
        existing_type=sa.Float(), type_=sa.Numeric(10, 2),
        existing_nullable=True,
    )
    op.alter_column(
        'ciclos', 'gasto_total',
        existing_type=sa.Float(), type_=sa.Numeric(10, 2),
        existing_nullable=True,
    )
    op.alter_column(
        'ciclos', 'diaria',
        existing_type=sa.Float(), type_=sa.Numeric(10, 2),
        existing_nullable=True,
    )

    # Dias
    op.alter_column(
        'dias', 'saldo',
        existing_type=sa.Float(), type_=sa.Numeric(10, 2),
        existing_nullable=True,
    )

    # Gastos
    op.alter_column(
        'gastos_dia', 'valor',
        existing_type=sa.Float(), type_=sa.Numeric(10, 2),
        existing_nullable=True,
    )


def downgrade() -> None:
    op.alter_column(
        'gastos_dia', 'valor',
        existing_type=sa.Numeric(10, 2), type_=sa.Float(),
        existing_nullable=True,
    )
    op.alter_column(
        'dias', 'saldo',
        existing_type=sa.Numeric(10, 2), type_=sa.Float(),
        existing_nullable=True,
    )
    op.alter_column(
        'ciclos', 'diaria',
        existing_type=sa.Numeric(10, 2), type_=sa.Float(),
        existing_nullable=True,
    )
    op.alter_column(
        'ciclos', 'gasto_total',
        existing_type=sa.Numeric(10, 2), type_=sa.Float(),
        existing_nullable=True,
    )
    op.alter_column(
        'ciclos', 'valor_total',
        existing_type=sa.Numeric(10, 2), type_=sa.Float(),
        existing_nullable=True,
    )
