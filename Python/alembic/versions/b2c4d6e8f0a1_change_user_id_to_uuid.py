"""change user id from int to uuid string

Revision ID: b2c4d6e8f0a1
Revises: 3e17707010d8
Create Date: 2026-08-16 14:30:00.000000

Muda users.id de Integer auto-increment para String(36) UUID.
Gera UUIDs para usuarios existentes e atualiza referencias em ciclos.id_usuario.

MySQL exige: drop FK → drop PK → alter column → re-add PK → re-add FK.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import uuid

# revision identifiers, used by Alembic.
revision: str = 'b2c4d6e8f0a1'
down_revision: Union[str, None] = '3e17707010d8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    connection = op.get_bind()

    # 1. Encontra e dropa a FK de ciclos → users (nome auto-gerado pelo MySQL)
    inspector = sa.inspect(connection)
    fks = inspector.get_foreign_keys('ciclos')
    for fk in fks:
        if fk['referred_table'] == 'users':
            op.drop_constraint(fk['name'], 'ciclos', type_='foreignkey')

    # 2. Dropa a unique constraint que referencia id_usuario
    op.drop_constraint('uix_ciclo_client_id_usuario', 'ciclos', type_='unique')

    # 3. Dropa PK de users (MySQL nao permite alterar tipo de coluna que e PK)
    connection.execute(sa.text("ALTER TABLE users DROP PRIMARY KEY"))

    # 4. Altera tipo de users.id para VARCHAR(36)
    connection.execute(sa.text("ALTER TABLE users MODIFY id VARCHAR(36) NOT NULL"))

    # 5. Altera tipo de ciclos.id_usuario para VARCHAR(36)
    connection.execute(sa.text("ALTER TABLE ciclos MODIFY id_usuario VARCHAR(36)"))

    # 6. Gera UUIDs para usuarios existentes e atualiza referencias
    users = connection.execute(sa.text("SELECT id FROM users")).fetchall()
    for (old_id,) in users:
        new_id = str(uuid.uuid4())
        connection.execute(
            sa.text("UPDATE users SET id = :new_id WHERE id = :old_id"),
            {"new_id": new_id, "old_id": old_id}
        )
        connection.execute(
            sa.text("UPDATE ciclos SET id_usuario = :new_id WHERE id_usuario = :old_id"),
            {"new_id": new_id, "old_id": old_id}
        )

    # 7. Re-cria PK em users.id
    connection.execute(sa.text("ALTER TABLE users ADD PRIMARY KEY (id)"))

    # 8. Re-cria FK em ciclos.id_usuario
    connection.execute(sa.text(
        "ALTER TABLE ciclos ADD CONSTRAINT ciclos_ibfk_users "
        "FOREIGN KEY (id_usuario) REFERENCES users(id)"
    ))

    # 9. Re-cria unique constraint
    op.create_unique_constraint('uix_ciclo_client_id_usuario', 'ciclos', ['client_id', 'id_usuario'])


def downgrade() -> None:
    raise NotImplementedError(
        "Nao e possivel fazer downgrade de UUID para Integer — "
        "os UUIDs gerados nao podem ser mapeados de volta para IDs sequenciais."
    )
