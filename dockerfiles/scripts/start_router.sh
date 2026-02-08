#!/bin/sh

echo "=== Router Gateway con Split Tunneling Inteligente ==="

VIP="${GATEWAY_VIP:-172.19.50.254}"
LAN_ROUTES="${NPM_LAN_ROUTES:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

# Habilitar IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

# Guardar el gateway por defecto original (para internet y fallback)
ORIGINAL_GW=$(ip route | grep "^default" | awk '{print $3}')
echo "Gateway original: $ORIGINAL_GW"
echo "VIP esperada: $VIP"
echo "Rutas LAN: $LAN_ROUTES"
echo ""

# Variables de estado
VPN_AVAILABLE=false

# Función para verificar si la VIP está disponible
check_vip() {
    ping -c 1 -W 2 "$VIP" >/dev/null 2>&1
}

# Función para configurar rutas via VPN
set_vpn_routes() {
    if [ -n "$LAN_ROUTES" ]; then
        echo "[VPN] Configurando rutas via VIP ($VIP)..."
        echo "$LAN_ROUTES" | tr ',' '\n' | while read -r route; do
            route=$(echo "$route" | tr -d ' ')
            if [ -n "$route" ]; then
                ip route replace "$route" via "$VIP" 2>/dev/null && \
                    echo "  + $route via $VIP" || \
                    echo "  ! Error agregando $route"
            fi
        done
    fi
}

# Función para configurar rutas via gateway directo (fallback)
set_direct_routes() {
    if [ -n "$LAN_ROUTES" ]; then
        echo "[DIRECT] Configurando rutas via gateway directo ($ORIGINAL_GW)..."
        echo "$LAN_ROUTES" | tr ',' '\n' | while read -r route; do
            route=$(echo "$route" | tr -d ' ')
            if [ -n "$route" ]; then
                ip route replace "$route" via "$ORIGINAL_GW" 2>/dev/null && \
                    echo "  + $route via $ORIGINAL_GW" || \
                    echo "  ! Error agregando $route"
            fi
        done
    fi
}

# Configurar iptables
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
iptables -P FORWARD ACCEPT

# NAT para trafico que va a internet (via gateway Docker)
# El trafico a VPN no necesita NAT aqui (lo hace el VPN gateway)
iptables -t nat -A POSTROUTING -o eth0 ! -d 172.19.50.0/24 -j MASQUERADE
echo "NAT configurado para trafico a internet"

# Verificación inicial - esperar un poco a que las VPNs arranquen
echo "Esperando inicio de VPNs (30s)..."
sleep 30

# Verificar estado inicial
if check_vip; then
    echo "[OK] VIP disponible - usando VPN"
    VPN_AVAILABLE=true
    set_vpn_routes
else
    echo "[WARN] VIP no disponible - usando gateway directo (fallback)"
    VPN_AVAILABLE=false
    set_direct_routes
fi

echo ""
echo "=== Router configurado ==="
echo "Tabla de rutas:"
ip route show
echo ""

# Monitoreo continuo
echo "Iniciando monitoreo cada ${CHECK_INTERVAL}s..."
while true; do
    sleep "$CHECK_INTERVAL"

    if check_vip; then
        # VIP disponible
        if [ "$VPN_AVAILABLE" = "false" ]; then
            echo ""
            echo "[CAMBIO] VPN disponible - cambiando rutas a VIP"
            VPN_AVAILABLE=true
            set_vpn_routes
            echo "Tabla de rutas actualizada:"
            ip route show | grep -E "$(echo $LAN_ROUTES | tr ',' '|')" || true
        fi
    else
        # VIP no disponible
        if [ "$VPN_AVAILABLE" = "true" ]; then
            echo ""
            echo "[CAMBIO] VPN no disponible - cambiando a gateway directo"
            VPN_AVAILABLE=false
            set_direct_routes
            echo "Tabla de rutas actualizada:"
            ip route show | grep -E "$(echo $LAN_ROUTES | tr ',' '|')" || true
        fi
    fi
done
