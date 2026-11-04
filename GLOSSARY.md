# Dokploy Architecture Glossary

## Remote Server Types

- **Deploy Server (Full Node)**: Полнофункциональный удаленный сервер Dokploy. Включает Docker Engine, инициализацию Docker Swarm mode, инстанс Traefik ingress (`dokploy-traefik`), overlay-сеть `dokploy-network`, бинарники сборщиков (Nixpacks, Buildpacks, Railpack) и стек мониторинга. Базовое потребление RAM: 450–550 МБ.
- **Build Server**: Сервер, выделенный исключительно под сборку Docker-образов для снятия нагрузки с главного инстанса Dokploy. Содержит Docker Engine и CLI-сборщики, не запускает Traefik и Swarm-сервисы.
- **Lightweight Worker**: Облегченный удаленный рабочий сервер Dokploy для маломощных хостов (RAM <= 1 ГБ, 1 vCPU). Содержит исключительно оптимизированный Docker Engine с рантаймом `crun`, настроенной защитой от OOM (ZRAM + Swapfile) и bridge-сетью `dokploy-network`. Не запускает Docker Swarm, Traefik, локальные сборщики и мониторинг. Базовое потребление RAM: 85–120 МБ.
