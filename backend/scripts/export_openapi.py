"""Prints the API description (OpenAPI JSON), stable and sorted.

    .venv/bin/python scripts/export_openapi.py > ../docs/openapi.json

The committed copy (docs/openapi.json) is the API's inventory: CI fails when
the code and the copy disagree, so every API change shows up in review.
Works without TRUSTPUNCH_DEBUG; the running server still hides the schema.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import create_app  # noqa: E402 - after the path setup above

if __name__ == "__main__":
    schema = create_app().openapi()
    sys.stdout.write(json.dumps(schema, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
