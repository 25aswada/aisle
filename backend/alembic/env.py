from alembic import context

try:
    from backend.app.config import get_settings
    from backend.app.database import make_engine
    from backend.app.models import Base
except ModuleNotFoundError:
    # Deployed with backend/ as the root (Heroku), where the package is just `app`.
    from app.config import get_settings
    from app.database import make_engine
    from app.models import Base

config = context.config
target_metadata = Base.metadata
url = config.get_main_option("sqlalchemy.url") or get_settings().database_url

if context.is_offline_mode():
    # Normalize deployment URLs in the same way as the application engine.
    if url.startswith(("postgres://", "postgresql://")):
        url = "postgresql+psycopg://" + url.split("://", 1)[1]
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = make_engine(url)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
