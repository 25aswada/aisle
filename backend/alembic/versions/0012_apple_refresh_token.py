"""Sign in with Apple identities keep Apple's refresh token, so deleting the account can
revoke the Apple sign-in."""
from alembic import op
import sqlalchemy as sa

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("user_identities") as batch:
        batch.add_column(sa.Column("apple_refresh_token", sa.String(500), nullable=True))


def downgrade():
    with op.batch_alter_table("user_identities") as batch:
        batch.drop_column("apple_refresh_token")
