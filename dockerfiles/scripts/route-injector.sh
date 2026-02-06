#!/bin/bash
# =============================================================
# Route Injector - Inyecta rutas automaticamente a contenedores
# =============================================================

set -e

NETWORK="${NETWORK_NAME:-vpn-proxy}"
ROUTER_IP="${ROUTER_IP:-172.19.50.1}"
# Contenedores a excluir (infraestructura)
EXCLUDE_CONTAINERS="${EXCLUDE_CONTAINERS:-router,wireguard_gw,fortinet_gw,route-injector}"

echo "=== Route Injector ==="
echo "Red monitoreada: $NETWORK"
echo "Router IP: $ROUTER_IP"
echo "Contenedores excluidos: $EXCLUDE_CONTAINERS"
echo ""

# Funcion para verificar si un contenedor debe ser excluido
should_exclude() {
    local container_name="$1"
    IFS=',' read -ra EXCLUDED <<< "$EXCLUDE_CONTAINERS"
    for excluded in "${EXCLUDED[@]}"; do
        if [ "$container_name" = "$excluded" ]; then
            return 0
        fi
    done
    return 1
}

# Funcion para inyectar ruta a un contenedor
inject_route() {
    local container_id="$1"
    local container_name

    # Obtener nombre del contenedor
    container_name=$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null | sed 's/^\///')

    if [ -z "$container_name" ]; then
        echo "[WARN] No se pudo obtener nombre del contenedor $container_id"
        return 1
    fi

    # Verificar si debe ser excluido
    if should_exclude "$container_name"; then
        echo "[SKIP] $container_name (excluido)"
        return 0
    fi

    # Verificar si el contenedor esta en la red objetivo
    local in_network
    in_network=$(docker inspect -f "{{index .NetworkSettings.Networks \"${NETWORK}\"}}" "$container_id" 2>/dev/null)

    if [ "$in_network" = "<no value>" ] || [ -z "$in_network" ] || [ "$in_network" = "map[]" ]; then
        echo "[SKIP] $container_name (no esta en red $NETWORK)"
        return 0
    fi

    # Obtener PID del contenedor
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$container_id" 2>/dev/null)

    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "[WARN] $container_name: No se pudo obtener PID"
        return 1
    fi

    # Inyectar ruta usando nsenter
    echo "[INJECT] $container_name (PID: $pid)"

    # Verificar que el proceso existe
    if ! [ -d "/proc/$pid" ]; then
        echo "[ERROR] $container_name: PID $pid no existe en /proc"
        return 1
    fi

    # Intentar inyectar la ruta
    if nsenter -t "$pid" -n ip route replace default via "$ROUTER_IP" 2>&1; then
        echo "[OK] $container_name: Ruta inyectada correctamente"
        nsenter -t "$pid" -n ip route show default 2>/dev/null | sed 's/^/       /'
        return 0
    else
        local err=$?
        echo "[ERROR] $container_name: Fallo nsenter (codigo: $err)"
        # Intentar mostrar mas info
        echo "       Verificando /proc/$pid/ns/net:"
        ls -la "/proc/$pid/ns/net" 2>&1 | sed 's/^/       /' || true
        return 1
    fi
}

# Inyectar rutas a contenedores existentes
echo ""
echo "=== Procesando contenedores existentes ==="
for container_id in $(docker ps -q); do
    inject_route "$container_id" || true
done

echo ""
echo "=== Monitoreando nuevos contenedores ==="

# Monitorear eventos de Docker
docker events \
    --filter 'type=container' \
    --filter 'event=start' \
    --format '{{.Actor.ID}}' | while read -r container_id; do

    # Pequena pausa para que el contenedor termine de inicializar su red
    sleep 1

    inject_route "$container_id" || true
done
