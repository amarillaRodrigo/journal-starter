# Despliegue containerizado en AWS EC2 (Terraform + ECR + SSM)

Este documento describe el despliegue **actual** del capstone: la API de Journal
corre como contenedor Docker en una instancia EC2, con PostgreSQL como contenedor
en la misma instancia, y toda la infraestructura provisionada con Terraform.

## Arquitectura

```text
Cliente público
   │  HTTP :8000
   ▼
Internet Gateway
   │
   ▼
EC2 t3.micro (Amazon Linux 2023)  ← Elastic IP 3.216.116.179
   ├── journal-api  (contenedor, puerto 8000)   imagen de ECR
   └── journal-db   (contenedor, postgres:16-alpine, red interna journal-net)
   ▲
   └── Acceso administrativo vía AWS Systems Manager (sin SSH, sin puerto 22)
```

* **Red:** VPC `10.0.0.0/16`, subnet pública `10.0.1.0/24`, IGW y route table.
* **Acceso:** solo el puerto **8000** está abierto a Internet. El puerto 22 está cerrado;
  la administración se hace con **SSM Run Command / Session Manager**.
* **IAM:** `journal-ssm-role` con `AmazonSSMManagedInstanceCore` (SSM) y
  `AmazonEC2ContainerRegistryReadOnly` (pull de ECR).
* **Persistencia:** volumen de Docker del contenedor `journal-db`.

## Secretos

Ningún secreto se hornea en la imagen ni se escribe en Terraform:

* `.env` y `k8s/secret.yaml` están en `.gitignore` y en `.dockerignore`.
* En AWS los secretos viven en **SSM Parameter Store** como `SecureString`:

| Parámetro | Tipo |
|---|---|
| `/journal-api/OPENAI_API_KEY` | SecureString |
| `/journal-api/POSTGRES_PASSWORD` | SecureString |
| `/journal-api/OPENAI_BASE_URL` | String |
| `/journal-api/OPENAI_MODEL` | String |

El `user_data` de la instancia los lee en el arranque con `aws ssm get-parameter
--with-decryption` y los inyecta como variables de entorno del contenedor.

Comandos para (re)cargar un secreto:

```powershell
aws ssm put-parameter --name /journal-api/OPENAI_API_KEY --value "sk-..." `
  --type SecureString --overwrite --region us-east-1
```

## Build y push de la imagen

La imagen recibe el commit SHA como `--build-arg`, queda en `ENV GIT_SHA` y se
expone en `GET /version`.

```powershell
$sha = git rev-parse --short HEAD
$reg = "607856468834.dkr.ecr.us-east-1.amazonaws.com"

aws ecr get-login-password --region us-east-1 |
  docker login --username AWS --password-stdin $reg

docker build --build-arg GIT_SHA=$sha -t journal-api:$sha -t journal-api:latest .
docker tag journal-api:$sha "$reg/journal-api:$sha"
docker tag journal-api:$sha "$reg/journal-api:latest"
docker push "$reg/journal-api:$sha"
docker push "$reg/journal-api:latest"
```

## Infraestructura

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

`terraform output` devuelve `api_url`, `public_ip`, `ecr_image` y `vpc_id`.

Para pinear una versión exacta en la instancia:

```powershell
terraform apply -var="image_tag=3dc9a69"
```

> Nota: cambiar `user_data` en una instancia existente **no** vuelve a ejecutarlo.
> Para re-bootstrap completo hay que recrear la instancia (`terraform apply -replace=aws_instance.journal_api`).

## Actualizar la aplicación (sin recrear infraestructura)

```powershell
# 1. build + push con el nuevo SHA (ver arriba)
# 2. reemplazar el contenedor vía SSM (sin abrir SSH)
aws ssm send-command --instance-ids <INSTANCE_ID> `
  --document-name "AWS-RunShellScript" `
  --parameters "commands=['sudo docker pull <ECR_IMAGE>:latest','sudo docker rm -f journal-api','sudo docker run -d --name journal-api --network journal-net --restart unless-stopped -p 8000:8000 -e DATABASE_URL=... <ECR_IMAGE>:latest']" `
  --region us-east-1
```

## Verificación

```powershell
Invoke-RestMethod http://3.216.116.179:8000/version   # {"commit":"<sha>"}
Invoke-RestMethod http://3.216.116.179:8000/entries   # {"entries":[...],"count":N}
Invoke-RestMethod http://3.216.116.179:8000/openapi.json
```

Comprobar que la imagen no contiene secretos:

```powershell
docker run --rm journal-api:latest ls -a /app   # no debe aparecer .env ni k8s/secret.yaml
```

## Destruir la infraestructura

```powershell
cd terraform
terraform destroy
```
