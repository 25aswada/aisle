"""Accounts get a plus_token, stamped on their App Store purchases so Aisle+ follows
the account that bought it."""
from uuid import uuid4

from alembic import op
import sqlalchemy as sa

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("users") as batch:
        batch.add_column(sa.Column("plus_token", sa.String(36), nullable=True))
    users = sa.table("users", sa.column("id", sa.Integer), sa.column("plus_token", sa.String))
    connection = op.get_bind()
    for (user_id,) in connection.execute(sa.select(users.c.id)).all():
        connection.execute(users.update().where(users.c.id == user_id).values(plus_token=str(uuid4())))
    with op.batch_alter_table("users") as batch:
        batch.alter_column("plus_token", existing_type=sa.String(36), nullable=False)
        batch.create_unique_constraint("uq_users_plus_token", ["plus_token"])


def downgrade():
    with op.batch_alter_table("users") as batch:
        batch.drop_constraint("uq_users_plus_token", type_="unique")
        batch.drop_column("plus_token")
