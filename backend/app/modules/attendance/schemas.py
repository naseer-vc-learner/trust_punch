"""Request and response models for punches (used by router and service)."""

from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field

from app.core.schemas import Strict

MAX_BATCH = 500


class PunchIn(Strict):
    id: UUID
    type: Literal["checkIn", "breakStart", "breakEnd", "checkOut"]
    at: AwareDatetime
    offsetMinutes: int = Field(ge=-14 * 60, le=14 * 60)
    workerId: str = Field(min_length=1, max_length=100)
    employeeId: str = Field(max_length=100)
    workerName: str = Field(max_length=200)
    siteId: str = Field(min_length=1, max_length=100)
    siteName: str = Field(max_length=200)
    # Where the phone has the location; missing when it was deleted since.
    siteLat: float | None = Field(default=None, ge=-90, le=90)
    siteLng: float | None = Field(default=None, ge=-180, le=180)
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    distance: float = Field(ge=0, le=20_000_000)
    auto: bool = False
    corrected: bool = False
    clockSuspect: bool = False
    replaces: UUID | None = None
    # How the worker made it; absent for automatic and corrected punches.
    via: Literal["ownPhone", "gate"] | None = None


class PunchBatch(Strict):
    # The phone's clock when it sent this, compared with the server's.
    sentAt: AwareDatetime
    punches: list[PunchIn] = Field(max_length=MAX_BATCH)


class Rejected(BaseModel):
    id: str
    reason: str


class UploadResult(BaseModel):
    accepted: list[str]
    duplicates: list[str]
    rejected: list[Rejected]
    flags: dict[str, list[str]]
    serverTime: str


class OpenSession(BaseModel):
    open: bool
    onThisPhone: bool
