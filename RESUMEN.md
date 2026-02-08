# Resumen del Proyecto

Este es un **stack de Docker para enrutamiento de tráfico a través de VPN** con alta disponibilidad y proxy reverso.

## Arquitectura Principal

El sistema implementa **split tunneling** donde:
- Tráfico a redes corporativas → va por VPN
- Tráfico a internet → sale directo por gateway Docker

## Componentes

| Servicio | IP | Función |
|----------|-----|---------|
| **router** | 172.19.50.1 | Gateway principal con split tunneling |
| **route-injector** | host | Inyecta rutas automáticamente a contenedores |
| **wireguard_gw** | 172.19.50.253 | VPN WireGuard (MASTER, prioridad 100) |
| **fortinet_gw** | 172.19.50.252 | VPN Fortinet (BACKUP, prioridad 50) |
| **npm** | 172.19.50.250 | Nginx Proxy Manager |

## Características Clave

- **Split Tunneling**: Solo tráfico corporativo va por VPN
- **Alta Disponibilidad**: Failover automático WireGuard ↔ Fortinet via Keepalived (VIP: 172.19.50.254)
- **Inyección automática de rutas**: Contenedores no necesitan `NET_ADMIN`
- **Proxy reverso**: Nginx Proxy Manager para SSL y dominios

## Estructura de Archivos

```
router_vpn_npm/
├── docker-compose.yaml        # Definición de servicios
├── .env                       # Configuración (no commitear)
├── .env.example               # Plantilla de configuración
├── dockerfiles/               # 5 Dockerfiles
│   ├── Dockerfile.router
│   ├── Dockerfile.route-injector
│   ├── Dockerfile.wireguard-ha
│   ├── Dockerfile.fortinet-ha
│   ├── Dockerfile.npm
│   └── scripts/               # Scripts de inicio
├── stack_data/                # Datos persistentes
├── init.sh                    # Script inicialización
└── get-fortinet-cert.sh       # Obtiene cert Fortinet
```

## Uso

Los contenedores que quieran usar la VPN solo necesitan conectarse a la red `vpn-proxy`:

```yaml
services:
  mi-app:
    networks:
      - vpn-proxy
```

El `route-injector` detectará automáticamente el contenedor y configurará su ruta.

## Flujo de Tráfico

```
Aplicación (red vpn-proxy)
         │
         ▼
Router (172.19.50.1) ─── Split Tunneling
         │
    ┌────┴────┐
    │         │
    ▼         ▼
  VPN       Internet
(VIP 254)  (GW Docker)
```
