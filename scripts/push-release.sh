#!/usr/bin/env bash
# Publica el commit actual en los dos remotes.
#
# Por que dos: el repo "journal-starter" es el canonico (standalone, es el que
# la plataforma de evaluacion resuelve por URL y el primero que debe quedar
# en verde) y "journal-starter-pipeline" es el espejo que venia corriendo el
# pipeline desde que GitHub deshabilito Actions en el fork original.
#
# Contexto: el fork de "learntocloud/journal-starter" quedo archivado como
# "journal-starter-fork" porque su organizacion de origen tiene Actions
# deshabilitado y el fork lo hereda (la API responde enabled=true, un PUT
# devuelve 204 y aun asi todo trigger falla con HTTP 422). El repo canonico se
# creo standalone con el mismo historial y el mismo nombre, asi que el sub de
# OIDC no cambio y la politica de confianza del rol sigue machacando.
#
# Uso: ./scripts/push-release.sh [rama]
set -euo pipefail

BRANCH="${1:-main}"

echo "==> Publicando en el repo canonico (journal-starter)"
git push origin "${BRANCH}"

echo "==> Publicando en el espejo (journal-starter-pipeline)"
git push pipeline "${BRANCH}"

echo "==> Listo. El pipeline corre sobre ${BRANCH} en los dos repos."
