#!/bin/bash
set -e

echo "=== NPM con rutas dinámicas hacia VIP ==="

# Variables
VIP="${GATEWAY_VIP:-172.19.50.254}"
LAN_ROUTES="${NPM_LAN_ROUTES:-}"
MAX_RETRIES=60

# Esperar a que la VIP esté disponible
echo "Esperando a que la VIP ($VIP) esté disponible..."
RETRY=0
until ping -c 1 -W 2 "$VIP" >/dev/null 2>&1; do
    RETRY=$((RETRY + 1))
    if [ $RETRY -ge $MAX_RETRIES ]; then
        echo "ADVERTENCIA: Timeout esperando VIP, continuando de todos modos..."
        break
    fi
    echo "Esperando VIP... ($RETRY/$MAX_RETRIES)"
    sleep 2
done

# Agregar rutas LAN si están configuradas
if [ -n "$LAN_ROUTES" ]; then
    echo "Configurando rutas LAN..."
    IFS=',' read -ra ROUTES <<< "$LAN_ROUTES"
    for route in "${ROUTES[@]}"; do
        route=$(echo "$route" | tr -d ' ')
        if [ -n "$route" ]; then
            if ip route show | grep -q "^$route"; then
                echo "Ruta $route ya existe, omitiendo..."
            else
                echo "Agregando ruta: $route via $VIP"
                ip route add "$route" via "$VIP" || echo "Error agregando ruta $route"
            fi
        fi
    done
fi

echo "=== Rutas configuradas ==="
ip route show | grep "$VIP" || echo "No hay rutas via VIP"

# Ejecutar NPM
echo "Iniciando Nginx Proxy Manager..."
exec /init "$@"
