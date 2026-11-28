"""Base models shared by every module's request bodies."""

from pydantic import BaseModel, ConfigDict


class Strict(BaseModel):
    """Unknown fields are refused, and so are NaN/Infinity in numbers."""

    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
