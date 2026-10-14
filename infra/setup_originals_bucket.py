#!/usr/bin/env python3
"""Bucket de originales de PinWatch y subida directa con URL prefirmada.
Uso, desde la raíz del repositorio:
  python3 infra/setup_originals_bucket.py
"""

import argparse
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ARN_PATTERN = re.compile(r"^arn:aws:iam::\d{12}:(user|role)/.+$")
ASSUMED_ROLE_PATTERN = re.compile(r"^arn:aws:sts::(\d{12}):assumed-role/([^/]+)/.+$")


def aws(*args, check=True):
    command = ["aws", *args]
    result = subprocess.run(command, text=True, capture_output=True)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SystemExit(f"Fallo: {' '.join(command)}\n{detail}")
    return result


def region():
    configured = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if configured:
        return configured.strip()
    configured = aws("configure", "get", "region", check=False).stdout.strip()
    if not configured:
        raise SystemExit("No hay región. Define AWS_REGION o ejecuta aws configure.")
    return configured


def iam_principal(arn):
    assumed_role = ASSUMED_ROLE_PATTERN.match(arn)
    if assumed_role:
        account, role = assumed_role.groups()
        return f"arn:aws:iam::{account}:role/{role}"
    return arn


def caller_identity(current_region):
    raw = aws(
        "sts",
        "get-caller-identity",
        "--output",
        "json",
        "--region",
        current_region,
    ).stdout
    try:
        identity = json.loads(raw)
    except json.JSONDecodeError:
        identity = {}
    account_id = str(identity.get("Account", "")).strip()
    arn = str(identity.get("Arn", "")).strip()
    if not account_id or not arn:
        raise SystemExit("No se pudo leer la cuenta. Revisa las credenciales de AWS CLI.")
    return account_id, iam_principal(arn)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "upload_principal_arn",
        nargs="?",
        help="ARN del usuario o rol que firma las URLs. Si se omite, se usa el de aws configure.",
    )
    args = parser.parse_args()
    current_region = region()
    account_id, caller_arn = caller_identity(current_region)
    principal = args.upload_principal_arn or caller_arn
    if not ARN_PATTERN.match(principal):
        raise SystemExit(
            "El ARN tiene que ser un usuario o rol de IAM. "
            "Revisa aws configure o pasa el ARN como argumento."
        )

    bucket = f"pinwatch-originals-{account_id}"
    cors_file = Path(__file__).resolve().parent / "originals-cors.json"

    exists = aws(
        "s3api",
        "head-bucket",
        "--bucket",
        bucket,
        "--region",
        current_region,
        check=False,
    )
    if exists.returncode != 0:
        create_args = ["s3api", "create-bucket", "--bucket", bucket, "--region", current_region]
        if current_region != "us-east-1":
            create_args += [
                "--create-bucket-configuration",
                f"LocationConstraint={current_region}",
            ]
        aws(*create_args)

    aws(
        "s3api",
        "put-public-access-block",
        "--bucket",
        bucket,
        "--region",
        current_region,
        "--public-access-block-configuration",
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true",
    )
    aws(
        "s3api",
        "put-bucket-ownership-controls",
        "--bucket",
        bucket,
        "--region",
        current_region,
        "--ownership-controls",
        "Rules=[{ObjectOwnership=BucketOwnerEnforced}]",
    )
    aws(
        "s3api",
        "put-bucket-encryption",
        "--bucket",
        bucket,
        "--region",
        current_region,
        "--server-side-encryption-configuration",
        "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]",
    )
    aws(
        "s3api",
        "put-bucket-cors",
        "--bucket",
        bucket,
        "--region",
        current_region,
        "--cors-configuration",
        f"file://{cors_file.as_posix()}",
    )

    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "PresignOriginalPinObjects",
                "Effect": "Allow",
                "Principal": {"AWS": principal},
                "Action": [
                    "s3:PutObject",
                    "s3:GetObject",
                    "s3:AbortMultipartUpload",
                    "s3:ListMultipartUploadParts",
                ],
                "Resource": f"arn:aws:s3:::{bucket}/originals/*",
            }
        ],
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as policy_file:
        json.dump(policy, policy_file)
        policy_path = policy_file.name
    try:
        aws(
            "s3api",
            "put-bucket-policy",
            "--bucket",
            bucket,
            "--region",
            current_region,
            "--policy",
            f"file://{Path(policy_path).as_posix()}",
        )
    finally:
        Path(policy_path).unlink(missing_ok=True)

    print(f"Bucket listo: {bucket} ({current_region})")
    print("Prefijo de los archivos originales: originals/")
    print(f"Principal autorizado a firmar la subida: {principal}")


if __name__ == "__main__":
    main()
