# Research Report: Dokploy Remote Deployment Mechanics (Ticket 01)

**Тикет:** `.scratch/lightweight-remote-server/issues/01-dokploy-remote-deployment-mechanics.md`  
**Цель:** Исследование архитектуры удаленного деплоя в Dokploy: используемые механизмы подключения, зависимость от Docker Swarm, поведение при развертывании Applications и Compose-проектов, а также последствия отсутствия инициализированного Swarm на удаленном сервере.

---

## 1. Executive Summary

1. **Транспорт удаленного деплоя:**
   Dokploy использует два независимых канала взаимодействия с удаленными серверами:
   - **SSH2 CLI / SFTP (`ssh2`)**: для удаленного клонирования репозиториев, наложения патчей, запуска сборщиков (`docker build`, `nixpacks`, `railpack`), записи конфигурационных файлов Traefik и выполнения CLI-команд Compose (`execAsyncRemote`, `writeFileRemote`).
   - **Dockerode over SSH**: для прямого управления Docker Engine через SSH-туннель к Docker daemon socket (`protocol: "ssh"` в `new Dockerode(...)`).

2. **Зависимость от Docker Swarm:**
   - **Applications (отдельные приложения): СТРОГО завязаны на Docker Swarm.** В Dokploy полностью отсутствует реализация запуска приложений через `docker run` или standalone `docker.createContainer`. Все приложения создаются исключительно как сервисы Docker Swarm (`docker.createService` / `service.update`).
   - **Databases (Postgres, MySQL, MariaDB, Mongo, Redis, LibSQL): СТРОГО завязаны на Docker Swarm.** Создаются как `docker.createService` через Dockerode.
   - **Compose-проекты: ГИБРИДНЫЕ.** Dokploy поддерживает два режима (`composeType`):
     - `docker-compose` (**дефолтный режим**): запускает классический `docker compose up -d` через SSH. Контейнеры разворачиваются как standalone Docker-контейнеры без Swarm.
     - `stack`: запускает `docker stack deploy` через SSH (требует Docker Swarm).
   - **Traefik Ingress: STANDALONE.** Сам Traefik на удаленном сервере разворачивается как одиночный Docker-контейнер (`docker run -d --name dokploy-traefik`), подключенный к сети `dokploy-network`.

3. **Что происходит, если Docker Swarm НЕ инициализирован:**
   - **Деплой Application:** **100% сбой.** Сборка образа завершится успешно, но на этапе `mechanizeDockerContainer` Docker daemon вернет ошибку `This node is not a swarm manager. Use "docker swarm init" or "docker swarm join"...`. Деплой переходит в статус `error`, контейнер не создается.
   - **Деплой Compose (`composeType: "stack"`):** **100% сбой.** Команда `docker stack deploy` завершится ошибкой отсутствия Swarm manager с exit code 1.
   - **Деплой Compose (`composeType: "docker-compose"`):** 
     - **При наличии доменов (стандартный кейс):** **Сбой.** Dokploy автоматически инжектирует в `docker-compose.yml` внешнюю сеть `dokploy-network: { external: true }`. Поскольку `dokploy-network` создается во время сетапа сервера как overlay-сеть (`--driver overlay`), без Swarm она не существует. `docker compose up` упадет с ошибкой `network dokploy-network declared as external, but could not be found`.
     - **В изолированном режиме (`isolatedDeployment: true`) или без доменов:** `docker compose up` **успешно запустится**, так как классическому compose swarm не нужен. Но Traefik не сможет проксировать трафик без общего сетевого моста.

---

## 2. Механизмы взаимодействия с Remote Server

В Dokploy подключение к удаленным серверам реализовано через два слоя:

### 2.1. SSH2 Remote Execution (`packages/server/src/utils/process/execAsync.ts`)

- **`execAsyncRemote(serverId, command, onData, input)`** (строки 173–290):
  - Загружает данные сервера и приватный SSH-ключ (`server.sshKey.privateKey`).
  - Устанавливает соединение через библиотеку `ssh2.Client` с keepalive (`sshKeepalive`: интервал 15 сек, 8 попыток, строка 8).
  - Выполняет команду в удаленной оболочке, осуществляет streaming вывода через `onData` и возвращает `{ stdout, stderr }`.
- **`writeFileRemote(serverId, remotePath, content)`** (строки 292–350):
  - Открывает SFTP-сессию через `conn.sftp()` и записывает файл на удаленный диск (используется для передачи файлов Traefik `.yml`, `.env` и т.д.).

### 2.2. Dockerode over SSH (`packages/server/src/utils/servers/remote-docker.ts`)

- **`getRemoteDocker(serverId)`** (строки 6–23):
  ```typescript
  export const getRemoteDocker = async (serverId?: string | null) => {
      if (!serverId) return docker;
      const server = await findServerById(serverId);
      if (!server.sshKeyId) return docker;
      const dockerode = new Dockerode({
          host: server.ipAddress,
          port: server.port,
          username: server.username,
          protocol: "ssh",
          sshOptions: {
              privateKey: server.sshKey?.privateKey,
              ...sshKeepalive,
          },
      });
      return dockerode;
  };
  ```
  Dockerode подключается к удаленному демону Docker через SSH-туннель. Через этот инстанс выполняются все высокоуровневые вызовы Docker API (создание сервисов, инспекция задач, управление сетями).

---

## 3. Архитектура деплоя Applications (Приложений)

### 3.1. Жизненный цикл деплоя (`packages/server/src/services/application.ts:187-247`)

1. **Клонирование и патчинг** (строки 203–223):
   Через `execAsyncRemote` выполняются команды клонирования (`cloneGithubRepository`, `cloneGitlabRepository` и т.д.) в директорию `/etc/dokploy/applications/<appName>/code`.
2. **Сборка образа** (строки 225–232):
   Формируется команда сборки через `getBuildCommand(application)` (`packages/server/src/utils/builders/index.ts:44-81`). В зависимости от типа приложения (`dockerfile`, `nixpacks`, `railpack`, `heroku`, `paketo`, `static`) вызывается соответствующий builder CLI, создающий локальный Docker-образ с тегом `<appName>:latest`.
3. **Запуск контейнера — `mechanizeDockerContainer`** (`packages/server/src/utils/builders/index.ts:83-245`):
   - Вызывается `getRemoteDocker(application.serverId)`.
   - Формируется спецификация `CreateServiceOptions` (Swarm Service Spec):
     - `TaskTemplate.ContainerSpec`: `Image: <appName>:latest`, `Env`, `Mounts`, `HealthCheck`, `Labels`.
     - `TaskTemplate.Networks`: `resolveServiceNetworks` возвращает `[{ Target: "dokploy-network" }]` (строка 168).
     - `TaskTemplate.Resources`: лимиты и резервации CPU/RAM.
     - `TaskTemplate.RestartPolicy`, `Placement`, `Mode` (реплики).
     - `EndpointSpec`: опубликованные порты.
     - `UpdateConfig`, `RollbackConfig`.
   - **Вызов Swarm API:**
     ```typescript
     // packages/server/src/utils/builders/index.ts:192-215
     try {
         const service = docker.getService(appName);
         const inspect = await service.inspect();
         forceUpdate = inspect.Spec.TaskTemplate.ForceUpdate + 1;
         await service.update({ ...settings, TaskTemplate: { ...settings.TaskTemplate, ForceUpdate: forceUpdate } });
     } catch (error) {
         if (authConfig) {
             await docker.createService(authConfig, settings);
         } else {
             await docker.createService(settings);
         }
     }
     ```
   - Ожидание конвергенции задач через Swarm Tasks API (`docker.listTasks(...)`, строки 220–244).
4. **Управление состоянием Applications:**
   - **Остановка (`stopServiceRemote`):** `packages/server/src/utils/docker/utils.ts:121-128`:
     `docker service scale ${appName}=0` через `execAsyncRemote`.
   - **Удаление (`removeService`):** `packages/server/src/utils/docker/utils.ts:453-469`:
     `docker service rm ${appName}` через `execAsyncRemote`.

**Вывод по Applications:** Приложения **100% завязаны на Docker Swarm**. Standalone `docker run` не предусмотрен.

---

## 4. Архитектура деплоя Compose-проектов

Схема таблицы `compose` (`packages/server/src/db/schema/compose.ts:43, 59`):
```typescript
export const composeType = pgEnum("composeType", ["docker-compose", "stack"]);
// default: "docker-compose"
```

### 4.1. Дефолтный режим: `composeType === "docker-compose"` (Classic Docker Compose)

1. **Генерация команды** (`packages/server/src/utils/builders/compose.ts:135-143`):
   ```typescript
   command = `compose -p ${quote([appName])} ${projectDirectoryFlag}${envFileFlag}-f ${quote([path])} up -d --build --remove-orphans${pullFlag}`;
   ```
2. **Скрипт выполнения** (`packages/server/src/utils/builders/compose.ts:53-73`):
   ```bash
   set -e
   {
       ${newCompose}     # Запись модифицированного compose файла
       ${envCommand}     # Запись .env файла
       cd "${projectPath}";
       env -i PATH="$PATH" HOME="$HOME" docker compose -p "<appName>" --project-directory "..." -f "docker-compose.yml" up -d --build --remove-orphans 2>&1
   }
   ```
3. **Исполнение:** выполняется через `execAsyncRemote(compose.serverId, commandWithLog)` (`packages/server/src/services/compose.ts:305`).
4. **Управление жизненным циклом Compose:**
   - **Start:** `docker compose -p <appName> -f <path> up -d` (`packages/server/src/services/compose.ts:490-496`).
   - **Stop:** `docker compose -p <appName> stop` (`packages/server/src/services/compose.ts:525-528`).
   - **Remove:** `docker compose -p <appName> down [--volumes]` (`packages/server/src/services/compose.ts:464-470`).
   - **Мониторинг контейнеров:** `docker ps -a --filter='label=com.docker.compose.project=<appName>'` (`packages/server/src/services/docker.ts:121`).

**Вывод:** В режиме `docker-compose` Dokploy запускает **настоящий классический Docker Compose**, порождающий обычные standalone-контейнеры.

### 4.2. Режим `composeType === "stack"` (Docker Swarm Stack)

- Генерирует команду: `docker stack deploy -c <path> <appName> --prune --with-registry-auth` (`packages/server/src/utils/builders/compose.ts:145`).
- Остановка и удаление: `docker stack rm <appName>` (`packages/server/src/services/compose.ts:453, 543`).
- Мониторинг: `docker stack ps <appName>` (`packages/server/src/services/docker.ts:176, 240`).

---

## 5. Взаимодействие с Traefik и Сетевая Модель

1. **Сеть `dokploy-network`:**
   При настройке сервера (`packages/server/src/setup/server-setup.ts:476`) создается сеть:
   ```bash
   docker network create --driver overlay --attachable dokploy-network
   ```
   Флаг `--driver overlay` **требует активного Docker Swarm**. Без Swarm команда завершается ошибкой.
2. **Инстанс Traefik (`packages/server/src/setup/server-setup.ts:771-782`):**
   Traefik запускается как **standalone-контейнер** (`docker run -d --name dokploy-traefik`), но подключается к общей overlay-сети:
   ```bash
   docker network connect dokploy-network dokploy-traefik
   ```
3. **Маршрутизация к Applications:**
   Dokploy пишет файл динамической конфигурации `/etc/dokploy/traefik/dynamic/${appName}.yml` через SFTP (`packages/server/src/utils/traefik/application.ts:269-281`).
   Traefik находит сервис по DNS-имени `${appName}` благодаря встроенному DNS-резолверу Docker Swarm в overlay-сети `dokploy-network`.
4. **Маршрутизация к Compose:**
   Dokploy модифицирует Compose-файл (`packages/server/src/utils/docker/domain.ts:353-397`), добавляя метки `traefik.enable=true`, `traefik.http.routers...` и подключая сервисы к `dokploy-network`. Traefik считывает эти метки напрямую через `/var/run/docker.sock`.

---

## 6. Что происходит, если Docker Swarm НЕ инициализирован?

### 6.1. При деплое Application
1. Шаг клонирования репозитория завершается успешно.
2. Шаг сборки Docker-образа (`docker build`) завершается успешно.
3. Вызывается `mechanizeDockerContainer` (`packages/server/src/utils/builders/index.ts:192`):
   - `docker.getService(appName).inspect()` -> падает с ошибкой API Docker:
     `503 Service Unavailable: This node is not a swarm manager. Use "docker swarm init" or "docker swarm join" to connect this node to swarm and try again.`
   - Код переходит в блок `catch (error)` (строка 208) и вызывает `docker.createService(settings)` (строка 213).
   - Вызов `/services/create` немедленно завершается с той же ошибкой: `This node is not a swarm manager.`
   - Ошибка не перехватывается, статус переходит в `error`.
   - **Результат: Ни один контейнер Application не запускается.**

### 6.2. При деплое Compose-проекта

#### Вариант А: `composeType === "stack"`
- Выполняется команда `docker stack deploy ...`.
- Ошибка Docker CLI: `This node is not a swarm manager.`
- **Результат: Деплой падает с ошибкой.**

#### Вариант Б: `composeType === "docker-compose"` (с привязанными доменами)
- Функция `writeDomainsToCompose` (`packages/server/src/utils/docker/domain.ts:400, 472-474, 651-669`) добавляет сеть `dokploy-network`:
  ```yaml
  networks:
    dokploy-network:
      external: true
  ```
- При выполнении `docker compose up -d`:
  Поскольку Swarm не был инициализирован, overlay-сеть `dokploy-network` не была создана.
  Docker Compose падает с ошибкой:
  `network dokploy-network declared as external, but could not be found`
- **Результат: Деплой падает с ошибкой.**

#### Вариант В: `composeType === "docker-compose"` (без доменов / isolatedDeployment)
- В `isolatedDeployment` создается локальная bridge-сеть:
  `docker network create --attachable <appName>`
- `docker compose up -d` **успешно запускает контейнеры**.
- **Результат:** Контейнеры работают, но внешняя маршрутизация через Traefik недоступна (если не открыты прямые host-порты).

---

## 7. Выводы для создания профиля `Lightweight Worker` (Low-RAM VPS)

1. **Compose — основной рабочий инструмент для легких нод:**
   Режим `docker-compose` уже использует нативный `docker compose CLI` и не требует Swarm.
2. **Критически важное исправление для сети без Swarm:**
   Если создать сеть `dokploy-network` как локальный bridge (`docker network create --driver bridge --attachable dokploy-network`), то:
   - Классический `docker compose up` с доменами начнет работать без Swarm.
   - Ошибка `network dokploy-network declared as external, but could not be found` исчезает!
3. **Applications:**
   Для запуска одиночных сервисов на легкой ноде пользователь может использовать простой Compose-манифест из одного сервиса с готовым образом (`image: myimage:tag`), либо Dokploy в будущем может добавить режим `mechanizeStandaloneContainer`.
