import os
import re
from pathlib import Path
from uuid import uuid4

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from mangum import Mangum
from pydantic import BaseModel, Field, field_validator

app = FastAPI(
    title="PinWatch API",
    description="API de PinWatch para publicar, explorar y organizar pines.",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


class PresignPin(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=2000)
    category: str = Field(min_length=1, max_length=80)
    filename: str = Field(min_length=1, max_length=255)
    content_type: str = Field(min_length=1, max_length=120)

    @field_validator("title", "category", "filename")
    @classmethod
    def required_text(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("Este campo es obligatorio.")
        return cleaned

    @field_validator("description")
    @classmethod
    def optional_text(cls, value: str) -> str:
        return value.strip()

    @field_validator("content_type")
    @classmethod
    def image_type(cls, value: str) -> str:
        content_type = value.strip()
        if not content_type.lower().startswith("image/"):
            raise ValueError("El archivo tiene que ser una imagen.")
        return content_type


class PresignUrl(BaseModel):
    url: str
    key: str
    content_type: str


_originals_bucket: str | None = None


def originals_bucket() -> str:
    global _originals_bucket
    if _originals_bucket:
        return _originals_bucket

    configured = os.environ.get("ORIGINALS_BUCKET", "").strip()
    if configured:
        _originals_bucket = configured
        return _originals_bucket

    try:
        account = boto3.client("sts").get_caller_identity()["Account"]
    except (BotoCoreError, ClientError) as error:
        raise HTTPException(
            status_code=503,
            detail="No se pudieron leer las credenciales de AWS.",
        ) from error

    _originals_bucket = f"pinwatch-originals-{account}"
    return _originals_bucket


def object_key(filename: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]", "_", Path(filename).name).strip("._") or "image"
    return f"originals/{uuid4()}/{name}"


def s3_client():
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    config = Config(
        signature_version="s3v4",
        request_checksum_calculation="when_required",
        response_checksum_validation="when_required",
    )
    if region:
        return boto3.client("s3", region_name=region, config=config)
    return boto3.client("s3", config=config)


@app.post("/pins/presign-url", response_model=PresignUrl)
def presign_pin_upload(pin: PresignPin) -> PresignUrl:
    key = object_key(pin.filename)
    try:
        url = s3_client().generate_presigned_url(
            "put_object",
            Params={
                "Bucket": originals_bucket(),
                "Key": key,
                "ContentType": pin.content_type,
            },
            ExpiresIn=900,
        )
    except (BotoCoreError, ClientError) as error:
        raise HTTPException(
            status_code=502,
            detail="No se pudo firmar la subida.",
        ) from error

    return PresignUrl(url=url, key=key, content_type=pin.content_type)


# Punto de entrada de AWS Lambda (API Gateway, Function URL o ALB).
handler = Mangum(app)
