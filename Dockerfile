# Usamos la imagen oficial de Python (más compatible y probada)
FROM python:3.11-slim

WORKDIR /app

# Instalar dependencias del sistema necesarias para asyncpg (compilación de C)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libpq-dev \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Copiar el archivo de dependencias primero (para aprovechar la cache de capas)
COPY requirements.txt .

# Instalar dependencias usando pip con solo wheels pre-compilados
RUN pip install --no-cache-dir --only-binary=:all: -r requirements.txt || \
    pip install --no-cache-dir -r requirements.txt

# Copiar el código fuente
COPY . .

# Exponer el puerto de la API
EXPOSE 8000

# Comando de ejecución
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]