#!/bin/bash
set -e

# Cleanup de procesos en background al salir
cleanup() {
    echo "Terminando procesos..."
    kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT TERM INT

echo "=== Fortinet VPN Gateway con HA (OpenConnect + Keepalived) ==="

# Limpiar PID files viejos de keepalived
rm -f /run/keepalived.pid /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid 2>/dev/null || true
mkdir -p /run/keepalived

# Variables de keepalived
KEEPALIVED_STATE="${KEEPALIVED_STATE:-BACKUP}"
KEEPALIVED_PRIORITY="${KEEPALIVED_PRIORITY:-50}"
KEEPALIVED_VRID="${KEEPALIVED_VRID:-50}"
KEEPALIVED_VIP="${KEEPALIVED_VIP:-172.19.50.254}"
KEEPALIVED_INTERFACE="${KEEPALIVED_INTERFACE:-eth0}"
KEEPALIVED_AUTH="${KEEPALIVED_AUTH:-vpnproxy}"

# Variables de VPN - openconnect usa tun0
export VPN_INTERFACE="${FORTICLIENT_INTERFACE:-tun0}"

# Verificar variables requeridas
if [ -z "$FORTICLIENT_HOST" ] || [ -z "$FORTICLIENT_PORT" ]; then
    echo "ERROR: Se requieren FORTICLIENT_HOST y FORTICLIENT_PORT"
    exit 1
fi

if [ -z "$FORTICLIENT_USER" ] || [ -z "$FORTICLIENT_PASSWORD" ]; then
    echo "ERROR: Se requieren FORTICLIENT_USER y FORTICLIENT_PASSWORD"
    exit 1
fi

echo "Servidor: ${FORTICLIENT_HOST}:${FORTICLIENT_PORT}"
echo "Usuario: ${FORTICLIENT_USER}"
echo "Interfaz VPN: ${VPN_INTERFACE}"

# Habilitar IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Generar configuración de keepalived
echo "Generando configuración de keepalived..."
export KEEPALIVED_STATE KEEPALIVED_PRIORITY KEEPALIVED_VRID KEEPALIVED_VIP KEEPALIVED_INTERFACE KEEPALIVED_AUTH VPN_INTERFACE
envsubst < /etc/keepalived/keepalived.conf.template > /etc/keepalived/keepalived.conf

echo "=== Configuración Keepalived ==="
cat /etc/keepalived/keepalived.conf
echo "================================"

# Función para iniciar keepalived
start_keepalived() {
    rm -f /run/keepalived.pid /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid 2>/dev/null || true
    keepalived -f /etc/keepalived/keepalived.conf --dont-fork --log-console &
    KEEPALIVED_PID=$!
    echo "Keepalived iniciado con PID: $KEEPALIVED_PID"
}

# Función para configurar NAT
configure_nat() {
    local max_retries=60
    local retry=0

    echo "Esperando interfaz VPN ($VPN_INTERFACE)..."

    while ! ip link show "$VPN_INTERFACE" >/dev/null 2>&1; do
        retry=$((retry + 1))
        if [ $retry -ge $max_retries ]; then
            echo "ERROR: Timeout esperando $VPN_INTERFACE"
            return 1
        fi
        sleep 2
    done

    echo "$VPN_INTERFACE detectado, esperando IP..."

    # Esperar a que la interfaz tenga IP asignada
    local ip_retry=0
    while ! ip addr show "$VPN_INTERFACE" 2>/dev/null | grep -q "inet "; do
        ip_retry=$((ip_retry + 1))
        if [ $ip_retry -ge 30 ]; then
            echo "WARN: Timeout esperando IP en $VPN_INTERFACE, continuando..."
            break
        fi
        sleep 1
    done

    echo "Configurando NAT..."

    # Limpiar reglas existentes
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

    # Iniciar keepalived
    echo "Iniciando keepalived (Estado: $KEEPALIVED_STATE, Prioridad: $KEEPALIVED_PRIORITY)..."
    start_keepalived

    echo "=== Fortinet HA Gateway iniciado ==="
    echo "VIP: $KEEPALIVED_VIP"

    # Monitorear keepalived
    while true; do
        if ! kill -0 $KEEPALIVED_PID 2>/dev/null; then
            echo "WARN: Keepalived murió, reiniciando..."
            start_keepalived
        fi
        sleep 10
    done
}

# Ejecutar configuración de NAT en background
configure_nat &

# Preparar opciones de openconnect
OPENCONNECT_OPTS="--protocol=fortinet"
OPENCONNECT_OPTS="$OPENCONNECT_OPTS --user=$FORTICLIENT_USER"
OPENCONNECT_OPTS="$OPENCONNECT_OPTS --passwd-on-stdin"
OPENCONNECT_OPTS="$OPENCONNECT_OPTS --interface=$VPN_INTERFACE"
# OPENCONNECT_OPTS="$OPENCONNECT_OPTS --verbose"  # Descomentar para debug

# Certificado - openconnect acepta formato pin-sha256:xxx
if [ -n "$FORTICLIENT_TRUSTED_CERT" ]; then
    OPENCONNECT_OPTS="$OPENCONNECT_OPTS --servercert=$FORTICLIENT_TRUSTED_CERT"
fi

# Agregar realm si está configurado
if [ -n "$FORTICLIENT_REALM" ]; then
    OPENCONNECT_OPTS="$OPENCONNECT_OPTS --authgroup=$FORTICLIENT_REALM"
fi

# Si no hay certificado configurado, permitir conexiones inseguras
if [ -z "$FORTICLIENT_TRUSTED_CERT" ]; then
    OPENCONNECT_OPTS="$OPENCONNECT_OPTS --no-cert-check"
fi

echo "Iniciando conexión VPN a ${FORTICLIENT_HOST}:${FORTICLIENT_PORT}..."
echo "Comando: openconnect $OPENCONNECT_OPTS https://${FORTICLIENT_HOST}:${FORTICLIENT_PORT}"

# Ejecutar openconnect pasando la contraseña por stdin
echo "$FORTICLIENT_PASSWORD" | exec openconnect $OPENCONNECT_OPTS "https://${FORTICLIENT_HOST}:${FORTICLIENT_PORT}"
