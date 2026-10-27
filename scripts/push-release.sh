#!/usr/bin/env bash
# Publica el commit actual en los dos remotes.
#
# Por que dos: GitHub deshabilito Actions en el fork "journal-starter" del lado
# de su plataforma (no es un ajuste del repo: la API responde enabled=true, un
# PUT devuelve 204 y aun asi todo trigger falla con HTTP 422). El pipeline
# corre en el repo espejo "journal-starter-pipeline", que si los ejecuta.
#
# El fork sigue siendo el remoto canonico (es el fork del capstone, con su
# historial y sus runs) y el espejo lleva el mismo historial, asi que ambos
# tienen el mismo codigo y el pipeline construye el commit que se acaba de
# publicar.
#
# Uso: ./scripts/push-release.sh [rama]
set -euo pipefail

BRANCH="${1:-main}"

echo "==> Publicando en el fork (canónico)"
git push origin "${BRANCH}"

echo "==> Publicando en el espejo (donde corre el pipeline)"
git push pipeline "${BRANCH}"

echo "==> Listo. El pipeline corre sobre ${BRANCH} en el repo espejo."
