#!/bin/sh
# Script de health check para keepalived
# Verifica que el túnel VPN esté activo y funcionando

VPN_INTERFACE="${VPN_INTERFACE:-tun0}"
HEALTH_CHECK_IP="${HEALTH_CHECK_IP:-8.8.8.8}"

# Verificar que la interfaz VPN exista
if ! ip link show "$VPN_INTERFACE" >/dev/null 2>&1; then
    exit 1
fi

# Verificar que la interfaz esté UP
if ! ip link show "$VPN_INTERFACE" | grep -q "state UP"; then
    # Algunos túneles no reportan state UP, verificar si tiene IP
    if ! ip addr show "$VPN_INTERFACE" | grep -q "inet "; then
        exit 1
    fi
fi

# Verificar conectividad
if ! ping -c 1 -W 3 "$HEALTH_CHECK_IP" >/dev/null 2>&1; then
    exit 1
fi

exit 0
