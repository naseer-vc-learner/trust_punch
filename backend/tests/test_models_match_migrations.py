"""The SQLAlchemy table definitions (models.py) and the migrations describe
the same tables. If someone changes one without the other, this fails and
names the difference."""

from alembic.autogenerate import compare_metadata
from alembic.runtime.migration import MigrationContext

import app.modules.auth.models
import app.modules.roles.models
import app.modules.tenancy.models
import app.modules.users.models  # noqa: F401 - registers the tables
from app.core.db import engine, metadata


def _only_modelled(obj, name, type_, reflected, compare_to):
    """Compare tables that have a models.py; older tables are not modelled yet."""
    table = name if type_ == "table" else getattr(getattr(obj, "table", None), "name", None)
    return table in metadata.tables


def test_models_and_migrations_agree(fresh_db):
    with engine(str(fresh_db)).connect() as conn:
        context = MigrationContext.configure(
            conn, opts={"include_object": _only_modelled, "compare_type": True}
        )
        diff = compare_metadata(context, metadata)
    assert diff == []
