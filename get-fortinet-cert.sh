#!/bin/bash
# =============================================================
# Obtiene el certificado SHA256 del servidor Fortinet
# y lo inyecta en compose/.env
# =============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/compose/.env"

echo "=== Obtener certificado Fortinet ==="
echo ""

# Verificar que existe .env
if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] No existe $ENV_FILE"
    echo "        Copia .env.example a .env primero"
    exit 1
fi

# Obtener host del .env o pedir al usuario
FORTICLIENT_HOST=$(grep -E "^FORTICLIENT_HOST=" "$ENV_FILE" | cut -d= -f2)
FORTICLIENT_PORT=$(grep -E "^FORTICLIENT_PORT=" "$ENV_FILE" | cut -d= -f2)
FORTICLIENT_PORT="${FORTICLIENT_PORT:-443}"

if [ -z "$FORTICLIENT_HOST" ]; then
    echo "FORTICLIENT_HOST no está configurado en .env"
    read -p "Ingresa el host del servidor Fortinet: " FORTICLIENT_HOST

    if [ -z "$FORTICLIENT_HOST" ]; then
        echo "[ERROR] Host no puede estar vacío"
        exit 1
    fi
fi

echo "Servidor: $FORTICLIENT_HOST:$FORTICLIENT_PORT"
echo ""

# Obtener certificado
echo "[INFO] Conectando al servidor..."
CERT_HASH=$(echo | openssl s_client -connect "$FORTICLIENT_HOST:$FORTICLIENT_PORT" 2>/dev/null | \
    openssl x509 -fingerprint -sha256 -noout 2>/dev/null | \
    sed 's/://g' | cut -d= -f2)

if [ -z "$CERT_HASH" ]; then
    echo "[ERROR] No se pudo obtener el certificado"
    echo "        Verifica que el servidor sea accesible"
    exit 1
fi

echo "[OK] Certificado obtenido:"
echo "     $CERT_HASH"
echo ""

# Verificar si ya existe en .env
CURRENT_CERT=$(grep -E "^FORTICLIENT_TRUSTED_CERT=" "$ENV_FILE" | cut -d= -f2)

if [ "$CURRENT_CERT" = "$CERT_HASH" ]; then
    echo "[OK] El certificado ya está configurado correctamente en .env"
    exit 0
fi

# Actualizar .env
if grep -q "^FORTICLIENT_TRUSTED_CERT=" "$ENV_FILE"; then
    # Reemplazar valor existente
    sed -i "s|^FORTICLIENT_TRUSTED_CERT=.*|FORTICLIENT_TRUSTED_CERT=$CERT_HASH|" "$ENV_FILE"
    echo "[OK] FORTICLIENT_TRUSTED_CERT actualizado en .env"
else
    # Agregar después de FORTICLIENT_HOST o al final de la sección Fortinet
    if grep -q "^FORTICLIENT_HOST=" "$ENV_FILE"; then
        sed -i "/^FORTICLIENT_HOST=/a FORTICLIENT_TRUSTED_CERT=$CERT_HASH" "$ENV_FILE"
    else
        echo "FORTICLIENT_TRUSTED_CERT=$CERT_HASH" >> "$ENV_FILE"
    fi
    echo "[OK] FORTICLIENT_TRUSTED_CERT agregado a .env"
fi

echo ""
echo "=== Listo ==="
