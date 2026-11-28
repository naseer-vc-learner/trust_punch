"""HTTP for pairing and the current device."""

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app.core.access import public
from app.core.schemas import Strict

from . import service
from .deps import Db, Device

router = APIRouter(tags=["devices"])


class PairRequest(Strict):
    code: str = Field(pattern=r"^\d{6}$")
    deviceName: str = Field(min_length=1, max_length=80)
    platform: Literal["ios", "android", "other"]


class PairResponse(BaseModel):
    deviceId: str
    token: str


class DeviceResponse(BaseModel):
    deviceId: str
    name: str


@router.post("/devices/pair", response_model=PairResponse, dependencies=[Depends(public)])
def pair(body: PairRequest, request: Request, db: Db) -> PairResponse:
    """Trades a one-time code from the server's operator for a device token."""
    client = request.client.host if request.client else "unknown"
    try:
        device_id, token = service.pair_device(
            db, body.code, body.deviceName, body.platform, client
        )
    except service.TooManyAttempts:
        raise HTTPException(
            429, "Too many wrong codes; wait and ask for a new one", headers={"Retry-After": "600"}
        ) from None
    except service.PairingRefused:
        raise HTTPException(403, "Code not valid") from None
    return PairResponse(deviceId=device_id, token=token)


@router.get("/devices/me", response_model=DeviceResponse)
def me(device: Device) -> DeviceResponse:
    return DeviceResponse(deviceId=device["id"], name=device["name"])
