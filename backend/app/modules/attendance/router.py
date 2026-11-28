"""HTTP for punch upload and the open-session question."""

from typing import Annotated

from fastapi import APIRouter, Path, Query

from app.modules.devices.deps import Db, Device

from . import service
from .schemas import OpenSession, PunchBatch, UploadResult

router = APIRouter(tags=["attendance"])


@router.get("/workers/{worker_id}/open-session", response_model=OpenSession)
def open_session(
    worker_id: Annotated[str, Path(min_length=1, max_length=100)],
    day: Annotated[str, Query(pattern=r"^\d{4}-\d{2}-\d{2}$")],
    device: Device,
    db: Db,
) -> OpenSession:
    """Whether the worker is checked in right now, and on which phone."""
    return service.open_session(db, worker_id, day, device["id"])


@router.post("/punches/batch", response_model=UploadResult)
def upload_punches(batch: PunchBatch, device: Device, db: Db) -> UploadResult:
    """Stores each punch once and returns what happened to each."""
    return service.upload(db, batch, device["id"])
