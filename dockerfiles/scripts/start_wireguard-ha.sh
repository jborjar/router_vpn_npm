#!/bin/bash
set -e

echo "=== WireGuard VPN Gateway con HA (Keepalived) ==="

# Limpiar PID files viejos de keepalived (previene "daemon is already running")
rm -f /run/keepalived.pid /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid 2>/dev/null || true
mkdir -p /run/keepalived

# Variables de keepalived
KEEPALIVED_STATE="${KEEPALIVED_STATE:-MASTER}"
KEEPALIVED_PRIORITY="${KEEPALIVED_PRIORITY:-100}"
KEEPALIVED_VRID="${KEEPALIVED_VRID:-50}"
KEEPALIVED_VIP="${KEEPALIVED_VIP:-172.19.50.254}"
KEEPALIVED_INTERFACE="${KEEPALIVED_INTERFACE:-eth0}"
KEEPALIVED_AUTH="${KEEPALIVED_AUTH:-vpnproxy}"

# Variables de VPN
export VPN_INTERFACE="tun0"

# Generar configuración de keepalived
echo "Generando configuración de keepalived..."
export KEEPALIVED_STATE KEEPALIVED_PRIORITY KEEPALIVED_VRID KEEPALIVED_VIP KEEPALIVED_INTERFACE KEEPALIVED_AUTH VPN_INTERFACE
envsubst < /etc/keepalived/keepalived.conf.template > /etc/keepalived/keepalived.conf

echo "=== Configuración Keepalived ==="
cat /etc/keepalived/keepalived.conf
echo "================================"

# Lanzar Gluetun en segundo plano
echo "Iniciando Gluetun (WireGuard)..."
/gluetun-entrypoint &
GLUETUN_PID=$!

# Esperar a que tun0 esté disponible
echo "Esperando a que $VPN_INTERFACE esté disponible..."
MAX_RETRIES=60
RETRY=0
until ip link show "$VPN_INTERFACE" >/dev/null 2>&1; do
    RETRY=$((RETRY + 1))
    if [ $RETRY -ge $MAX_RETRIES ]; then
        echo "ERROR: Timeout esperando $VPN_INTERFACE"
        exit 1
    fi
    sleep 2
done

echo "$VPN_INTERFACE detectado, configurando NAT..."

# Configurar NAT
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

# NAT para todo lo que salga por el túnel VPN
iptables -t nat -A POSTROUTING -o "$VPN_INTERFACE" -j MASQUERADE

# Permitir forwarding
for iface in $(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep '^eth'); do
    echo "Configurando FORWARD: $iface <-> $VPN_INTERFACE"
    iptables -A FORWARD -i "$iface" -o "$VPN_INTERFACE" -j ACCEPT
    iptables -A FORWARD -i "$VPN_INTERFACE" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT
done

echo "=== Reglas NAT configuradas ==="
iptables -t nat -L -n -v
iptables -L FORWARD -n -v

# Función para iniciar keepalived
start_keepalived() {
    rm -f /run/keepalived.pid /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid 2>/dev/null || true
    keepalived -f /etc/keepalived/keepalived.conf --dont-fork --log-console &
    KEEPALIVED_PID=$!
    echo "Keepalived iniciado con PID: $KEEPALIVED_PID"
}

# Iniciar keepalived
echo "Iniciando keepalived (Estado: $KEEPALIVED_STATE, Prioridad: $KEEPALIVED_PRIORITY)..."
start_keepalived

echo "=== WireGuard HA Gateway iniciado ==="
echo "VPN PID: $GLUETUN_PID"
echo "VIP: $KEEPALIVED_VIP"

# Monitorear ambos procesos
while true; do
    # Verificar Gluetun
    if ! kill -0 $GLUETUN_PID 2>/dev/null; then
        echo "ERROR: Gluetun ha terminado"
        exit 1
    fi

    # Verificar y reiniciar keepalived si murió
    if ! kill -0 $KEEPALIVED_PID 2>/dev/null; then
        echo "WARN: Keepalived murió, reiniciando..."
        start_keepalived
    fi

    sleep 10
done
