#!/bin/bash
# =============================================================
# Script de inicializacion para VPN Proxy Stack
# =============================================================

set -e

# Obtener directorio del script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Cargar variables del .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    # Proteger archivo con permisos restrictivos (solo propietario puede leer/escribir)
    chmod 600 "$SCRIPT_DIR/.env"
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# Configuracion de red (con valores por defecto)
NETWORK_NAME="${NETWORK_NAME:-vpn-proxy}"
NETWORK_SUBNET="${NETWORK_SUBNET:-172.19.50.0/24}"
NETWORK_GATEWAY="${NETWORK_GATEWAY:-172.19.50.200}"
DATA_PATH="${DATA_PATH:-./stack_data}"

# Resolver ruta relativa de DATA_PATH (relativa a SCRIPT_DIR)
if [[ "$DATA_PATH" != /* ]]; then
    DATA_PATH="$SCRIPT_DIR/$DATA_PATH"
fi

echo "=== VPN Proxy Stack - Inicializacion ==="
echo ""

# =============================================================
# 1. Detener y eliminar contenedores existentes
# =============================================================
echo "=== Verificando contenedores existentes ==="

cd "$SCRIPT_DIR"

if docker compose ps -q 2>/dev/null | grep -q .; then
    echo "[STOP] Deteniendo contenedores..."
    docker compose down --remove-orphans
    echo "[OK] Contenedores eliminados"
else
    echo "[OK] No hay contenedores corriendo"
fi

echo ""

# =============================================================
# 2. Verificar/Recrear red Docker
# =============================================================
echo "=== Verificando red Docker ==="

recreate_network=false

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    # Red existe, verificar configuracion
    CURRENT_SUBNET=$(docker network inspect "$NETWORK_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
    CURRENT_GATEWAY=$(docker network inspect "$NETWORK_NAME" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')

    echo "[CHECK] Red '$NETWORK_NAME' existe"
    echo "        Subnet actual: $CURRENT_SUBNET (esperado: $NETWORK_SUBNET)"
    echo "        Gateway actual: $CURRENT_GATEWAY (esperado: $NETWORK_GATEWAY)"

    if [ "$CURRENT_SUBNET" != "$NETWORK_SUBNET" ] || [ "$CURRENT_GATEWAY" != "$NETWORK_GATEWAY" ]; then
        echo "[WARN] Configuracion incorrecta, recreando red..."
        recreate_network=true
    else
        echo "[OK] Configuracion correcta"
    fi
else
    echo "[INFO] Red '$NETWORK_NAME' no existe"
    recreate_network=true
fi

if [ "$recreate_network" = true ]; then
    # Eliminar red si existe (y tiene contenedores desconectados)
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        echo "[DELETE] Eliminando red existente..."
        docker network rm "$NETWORK_NAME" 2>/dev/null || true
    fi

    echo "[CREATE] Creando red '$NETWORK_NAME'..."
    docker network create \
        --driver bridge \
        --subnet "$NETWORK_SUBNET" \
        --gateway "$NETWORK_GATEWAY" \
        "$NETWORK_NAME"
    echo "[OK] Red creada"
    echo "     Subnet: $NETWORK_SUBNET"
    echo "     Gateway: $NETWORK_GATEWAY"
fi

echo ""

# =============================================================
# 3. Crear directorios de datos
# =============================================================
echo "=== Verificando directorios de datos ==="

for dir in gluetun forticlient/logs npm/data npm/letsencrypt; do
    full_path="$DATA_PATH/$dir"
    if [ ! -d "$full_path" ]; then
        echo "[CREATE] $full_path"
        mkdir -p "$full_path"
    else
        echo "[OK] $full_path"
    fi
done

echo ""

# =============================================================
# 4. Levantar stack
# =============================================================
echo "=== Levantando stack ==="

cd "$SCRIPT_DIR"
docker compose up -d --build

echo ""
echo "=== Stack iniciado ==="
echo ""
docker compose ps
