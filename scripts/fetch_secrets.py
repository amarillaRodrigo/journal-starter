#!/usr/bin/env python3
"""Descarga los secretos de AWS Secrets Manager a un directorio local del pod.

Corre como *init container*: deja el material sensible en un ``emptyDir`` del
pod, nunca en un Secret de Kubernetes (que vive en etcd codificado en base64)
ni en el spec del pod (que es legible por cualquiera con ``get pods``).

La identidad que usa NO es la de la instancia: asume el rol de servicio de la
app (``journal-api-runtime-role``), que solo tiene ``GetSecretValue`` sobre los
dos secretos del proyecto.

Sobre el isolation
------------------
El ``ExternalId`` del ``AssumeRole`` es el ``sub`` del token de ServiceAccount
del pod (``system:serviceaccount:journal-api:journal-api``). Eso impide el uso
*accidental* del rol por otro servicio, pero NO es una frontera de seguridad
frente a un atacante: el valor esta en el repo, y en k3s cualquier pod puede
alcanzar IMDS (hop limit 2) y obtener las credenciales del instance profile.
El aislamiento real por pod requiere que AWS valide criptograficamente el
token, es decir IRSA o EKS Pod Identity, que necesitan un issuer OIDC publico.
Ver docs/delivery.md.

Uso:
    python /app/scripts/fetch_secrets.py <secret-id> [<secret-id> ...]

Variables de entorno:
    AWS_RUNTIME_ROLE_ARN  rol de servicio de la app (obligatorio)
    AWS_REGION            region de los secretos (default us-east-1)
    SECRETS_DIR           directorio de destino (default /secrets)
    SA_TOKEN_PATH         token de ServiceAccount (default el de Kubernetes)
"""

from __future__ import annotations

import base64
import json
import os
import stat
import sys
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# Es una ruta, no una credencial: S105 lo marca por el nombre.
DEFAULT_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"  # noqa: S105
DEFAULT_SECRETS_DIR = "/secrets"


def service_account_subject(token_path: str) -> str:
    """Devuelve el 'sub' del token de ServiceAccount del pod.

    Solo se lee el claim: no se valida la firma, porque la validacion la hace
    AWS a traves del ExternalId de la trust policy.
    """
    token = Path(token_path).read_text(encoding="utf-8").strip()
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    subject = claims.get("sub")
    if not subject:
        raise RuntimeError(f"el token de ServiceAccount no tiene claim 'sub': {token_path}")
    return subject


def assume_runtime_role(subject: str) -> dict[str, str]:
    """Asume el rol de la app con las credenciales del instance profile.

    boto3 resuelve las credenciales del nodo por la cadena por defecto, que
    incluye IMDS en una instancia EC2. La sesion asumida solo tiene lo que
    permite la policy del rol de destino.
    """
    role_arn = os.environ.get("AWS_RUNTIME_ROLE_ARN")
    if not role_arn:
        raise RuntimeError("falta la variable de entorno AWS_RUNTIME_ROLE_ARN")

    region = os.environ.get("AWS_REGION", "us-east-1")
    sts = boto3.client("sts", region_name=region)
    response = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName="journal-api-init",
        ExternalId=subject,
        DurationSeconds=3600,
    )
    creds = response["Credentials"]
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"],
    }


def read_secret(secret_id: str, creds: dict[str, str]) -> dict[str, str]:
    """Lee un secreto y lo devuelve como diccionario clave -> valor."""
    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region, **creds)
    raw = client.get_secret_value(SecretId=secret_id)["SecretString"]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = {"VALUE": raw}
    if not isinstance(data, dict):
        data = {"VALUE": str(data)}
    return {str(k): str(v) for k, v in data.items()}


def write_secret_file(directory: Path, key: str, value: str) -> None:
    """Escribe un valor en su propio archivo, legible solo por root."""
    path = directory / key
    path.write_text(value, encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)  # 0600


def main(argv: list[str]) -> int:
    secret_ids = argv[1:]
    if not secret_ids:
        print("uso: fetch_secrets.py <secret-id> [<secret-id> ...]", file=sys.stderr)
        return 2

    directory = Path(os.environ.get("SECRETS_DIR", DEFAULT_SECRETS_DIR))
    directory.mkdir(parents=True, exist_ok=True)
    token_path = os.environ.get("SA_TOKEN_PATH", DEFAULT_TOKEN_PATH)

    try:
        subject = service_account_subject(token_path)
        creds = assume_runtime_role(subject)
        written = 0
        for secret_id in secret_ids:
            for key, value in read_secret(secret_id, creds).items():
                write_secret_file(directory, key, value)
                written += 1
        print(f"secretos descargados: {written} valores en {directory}")
    except (BotoCoreError, ClientError) as exc:
        print(f"ERROR: no se pudieron leer los secretos: {exc}", file=sys.stderr)
        return 1
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
