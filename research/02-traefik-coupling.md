# Research Report: Traefik Coupling on Remote Servers (Ticket 02)

**Ticket:** `.scratch/lightweight-remote-server/issues/02-traefik-coupling-on-remote-servers.md`  
**Цель:** Исследование связности деплоя с Traefik на удаленных серверах и выявление возможности полного и безопасного исключения Traefik.

---

## 1. Executive Summary

1. **Связность деплоя с Traefik:**
   - **Applications (`deployApplication`):** Деплой **не взаимодействует** с контейнером Traefik или его API во время сборки/запуска. Динамические конфиги Traefik обновляются отдельно при создании/редактировании доменов. Однако Applications запускаются как сервисы Docker Swarm (`mechanizeDockerContainer`) и по умолчанию подключаются к сети `dokploy-network` (если не включен флаг `detachDokployNetwork: true`).
   - **Docker Compose (`deployCompose`):** Если у compose-сервисов нет назначенных доменов (`domains.length === 0`), проект **на 100% изолирован от Traefik и сети `dokploy-network`**. Никакие метки Traefik и внешние сети не инжектируются в `docker-compose.yml`.

2. **Запись конфигураций Traefik и проверки контейнера:**
   - Dokploy **НЕ пишет** динамические файлы конфигурации Traefik через SFTP/SSH во время деплоя (`deployApplication` или `deployCompose`).
   - Файлы YAML (`/etc/dokploy/traefik/dynamic/${appName}.yml`) записываются через SFTP (`writeFileRemote`) исключительно при операциях с доменами (`manageDomain`).
   - Dokploy **никогда не проверяет**, запущен ли контейнер `dokploy-traefik` во время деплоя.

3. **Поведение при отсутствии или остановке Traefik:**
   - **Контейнер Traefik остановлен или отсутствует:** Деплой Applications и Compose завершается со статусом `"done"` (без ошибок), при условии что сеть `dokploy-network` существует (или у приложения включен `detachDokployNetwork: true`).
   - **Запись доменов при отсутствии папок Traefik:** Ошибка SFTP в `writeTraefikConfigRemote` перехватывается в `try ... catch` и пишется в `console.error`, не прерывая выполнение и не вызывая исключения.
   - **Кастомный сетап:** Механизм `server.command` в `packages/server/src/setup/server-setup.ts:306` уже позволяет полностью переопределить стандартный 14-шаговый скрипт сетапа и исключить запуск Traefik.

---

## 2. Детали реализации в кодовой базе Dokploy

### 2.1. Жизненный цикл деплоя Applications (`packages/server/src/services/application.ts:178-265`)
- Запуск приложения выполняется через `mechanizeDockerContainer(application)` (`packages/server/src/utils/builders/index.ts:83-245`).
- Вся логика завязана на Dockerode и Docker Swarm API. В процессе деплоя **нет ни одного вызова Traefik** и ни одной попытки проверить контейнер `dokploy-traefik`.
- Сеть: по умолчанию `resolveServiceNetworks` (`packages/server/src/services/network.ts:363-388`) добавляет приложение к `dokploy-network`. Если флаг `detachDokployNetwork: true`, сеть не добавляется вовсе.

### 2.2. Жизненный цикл деплоя Compose (`packages/server/src/services/compose.ts:228-358`)
- В функции `addDomainToCompose` (`packages/server/src/utils/docker/domain.ts:268-416`):
  - Если список `domains` пуст, `declareUsedNetworksInRoot` проверяет `isUsed("dokploy-network")`. Так как сервисы его не используют, сеть `dokploy-network` **не добавляется в compose-файл**.
  - Результат: итоговый compose-файл имеет **0 меток Traefik** и **0 внешних сетей**.
- Единственное потенциальное место: в `packages/server/src/utils/builders/compose.ts:66`:
  ```bash
  ${compose.isolatedDeployment ? `docker network connect ${compose.appName} $(docker ps --filter "name=dokploy-traefik" -q) >/dev/null 2>&1` : ""}
  ```
  При `isolatedDeployment: true` и отсутствии `dokploy-traefik` строка может завершиться ошибкой под `set -e`. Достаточно добавить `|| true`. По умолчанию `isolatedDeployment === false`.

### 2.3. Запись динамических файлов Traefik (`packages/server/src/utils/traefik/application.ts:314-327`)
- Функция `writeTraefikConfigRemote`:
  ```typescript
  export const writeTraefikConfigRemote = async (
      traefikConfig: FileConfig,
      appName: string,
      serverId: string,
  ) => {
      try {
          const { DYNAMIC_TRAEFIK_PATH } = paths(true);
          const configPath = path.join(DYNAMIC_TRAEFIK_PATH, `${appName}.yml`);
          const yamlStr = stringify(traefikConfig);
          await writeFileRemote(serverId, configPath, yamlStr);
      } catch (e) {
          console.error("Error saving the YAML config file:", e);
      }
  };
  ```
  Даже если папка `/etc/dokploy/traefik` на удаленном сервере отсутствует, ошибка логируется, но не крашит систему.

### 2.4. Валидация сервера (`packages/server/src/setup/server-validate.ts`)
- Проверка `validateTraefik()` лишь возвращает `{ version: "0.0.0", enabled: false }` для отображения статуса в UI-карточке `ValidateServer`. Она **не блокирует** деплой проектов на сервер.

---

## 3. Выводы для создания профиля `Lightweight Worker`

1. **Traefik можно безопасно и полностью убрать с удаленной ноды**:
   - Приложения и Compose-проекты запускаются без ошибок при отсутствующем контейнере Traefik.
   - Экономия: **60–100 МБ RAM** постоянного потребления и высвобождение портов 80/443.
2. **Как маршрутизировать трафик**:
   - Прямой маппинг портов в Docker/Compose (`ports: ["8080:80"]`).
   - Либо внешний туннель (Cloudflare Tunnel).
   - Либо обратный прокси на главном инстансе Dokploy.
3. **Требование к сети**:
   - Чтобы деплой Compose с доменами или деплой Applications не падал при дефолтных настройках, достаточно создать простую bridge-сеть `dokploy-network` (`docker network create --driver bridge --attachable dokploy-network`), даже если Traefik не запущен.
