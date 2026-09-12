# Laravel Docker dev/prod parity Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Перебудувати Docker-оточення Laravel так, щоб локальна розробка і VPS використовували однакові версії PHP, Nginx, MariaDB, Composer і Node, без появи root:root у файлах проєкту.

**Architecture:** Локальний Docker використовує bind mount вихідного коду, vendor і node_modules, щоб Zed бачив та індексував залежності. Composer, Node і PHP-контейнер запускаються від UID/GID користувача хоста. Production використовує зібраний PHP image без bind mounts: код, Composer-залежності та frontend assets знаходяться всередині image.

**Tech Stack:**

- nginx:1.30.4-alpine
- mariadb:11.8.9
- php:8.5-fpm-bookworm
- composer:2.9.8
- node:24-bookworm-slim
- Docker Compose
- Laravel
- Vite

**Spec:** Вимоги з цього handoff-плану та попереднього обговорення.

## Global Constraints

- Не використовувати Laravel Sail, Herd або OpenServer.
- Не змінювати PHP-код, маршрути, моделі та бізнес-логіку.
- Не додавати Debugbar або інші пакети в межах цієї задачі.
- Зберегти вказані версії Docker images.
- Не запускати Composer, npm або Artisan від root, якщо команда пише у bind-mounted директорії.
- Не комітити vendor, node_modules, .env, public/build та public/hot.
- Не видаляти Docker volumes бази даних.
- Не перезаписувати існуючий .env.
- Перед змінами перевірити git status і зберегти всі сторонні зміни користувача.

---

### Task 1: Перевірити поточний стан

**Files to inspect:**

- /home/lex/Projects/tmp/docker-compose.yml
- /home/lex/Projects/tmp/docker/php/Dockerfile
- /home/lex/Projects/tmp/docker/nginx/default.conf
- /home/lex/Projects/tmp/Makefile
- /home/lex/Projects/tmp/.dockerignore
- /home/lex/Projects/tmp/.env.example
- /home/lex/Projects/tmp/composer.json
- /home/lex/Projects/tmp/package.json
- /home/lex/Projects/tmp/vite.config.js
- /home/lex/Projects/tmp/.gitignore

**Steps:**

- Перевірити поточний git status.
- Перевірити PHP-залежності через composer show --direct.
- Перевірити npm scripts у package.json.
- Перевірити поточні Docker mounts, users, ports та networks.
- Перевірити extensions у Dockerfile.
- Перевірити, чи існують vendor, node_modules, public/build, public/hot.
- Запустити:

~~~bash
cd /home/lex/Projects/tmp

docker compose config --quiet
git diff --check
~~~

Не переходити до редагування, якщо поточні користувацькі зміни потребують окремого узгодження.

---

### Task 2: Перебудувати PHP Dockerfile на multi-stage image

**Modify:**

- /home/lex/Projects/tmp/docker/php/Dockerfile

Створити stages:

1. php_base на основі php:8.5-fpm-bookworm з усіма потрібними extensions, зокрема pdo_mysql. PHP-FPM має запускатися у foreground.
2. vendor на основі composer:2.9.8. Скопіювати application source і Composer manifests, виконати production install із --no-dev, --prefer-dist, --no-interaction та --optimize-autoloader, а потім package discovery.
3. assets на основі node:24-bookworm-slim. Виконати npm ci, скопіювати frontend source та виконати npm run build. Результатом має бути public/build.
4. development на основі php_base. Робочий application source надходить через dev bind mount.
5. production на основі php_base. Скопіювати source, vendor з Composer stage і public/build з assets stage.

У production stage створити та передати www-data такі runtime-директорії:

- storage/framework/cache
- storage/framework/sessions
- storage/framework/views
- storage/logs
- bootstrap/cache

Production image не повинен залежати від host filesystem.

---

### Task 3: Спрощене локальне Docker Compose-оточення

**Modify:**

- /home/lex/Projects/tmp/docker-compose.yml

Залишити файл локальним dev Compose із сервісами app, nginx, db, composer і node.

Додати явну network:

~~~yaml
networks:
    app:
        driver: bridge
~~~

Усі dev-сервіси підключити до app.

#### app

- build target: development;
- user: "${HOST_UID:-1000}:${HOST_GID:-1000}";
- bind mount .:/var/www/html;
- не використовувати named volume для vendor або node_modules.

#### composer

- image: composer:2.9.8;
- user: "${HOST_UID:-1000}:${HOST_GID:-1000}";
- bind mount .:/var/www/html;
- запускати Composer без root;
- не додавати глобальний safe.directory, коли UID збігається з host user.

#### node

- image: node:24-bookworm-slim;
- user: "${HOST_UID:-1000}:${HOST_GID:-1000}";
- bind mount .:/var/www/html;
- не використовувати named volume для node_modules;
- Vite має писати public/hot, public/build та інші generated files від host user;
- зберегти CHOKIDAR_USEPOLLING=true, якщо він потрібен для filesystem events.

#### nginx

- image: nginx:1.30.4-alpine;
- bind mount .:/var/www/html:ro;
- конфігурацію монтувати read-only;
- Nginx не повинен записувати у application source.

#### db

- image: mariadb:11.8.9;
- named volume тільки для MariaDB data;
- healthcheck;
- host port configurable через .env;
- не створювати bind mount для MariaDB data.

---

### Task 4: Production Compose для VPS

**Create:**

- /home/lex/Projects/tmp/docker-compose.prod.yml
- /home/lex/Projects/tmp/docker/nginx/Dockerfile

Production Compose не повинен мати bind mount application source.

#### Production app

- build target: production;
- runtime на тому самому php:8.5-fpm-bookworm;
- запуск від www-data;
- без source bind mount;
- без Composer service;
- без Node service;
- PHP-FPM port не публікувати назовні.

#### Production nginx

/home/lex/Projects/tmp/docker/nginx/Dockerfile має базуватися на nginx:1.30.4-alpine і копіювати production default.conf у image.

Для передачі public між app і Nginx використати named volume:

~~~yaml
volumes:
    laravel_public:
~~~

PHP image має містити public/build, а Nginx монтує volume read-only:

~~~yaml
- laravel_public:/var/www/html/public:ro
~~~

Перевірити, що обидва контейнери бачать /var/www/html/public/build/manifest.json.

#### Production db

- image: mariadb:11.8.9;
- named volume для даних;
- порт не публікувати назовні за замовчуванням;
- доступ до MariaDB лише через Docker network;
- credentials передавати через server .env.

Production environment має містити:

~~~text
APP_ENV=production
APP_DEBUG=false
DB_HOST=db
DB_PORT=3306
~~~

Не генерувати APP_KEY автоматично під час кожного production запуску.

---

### Task 5: Спростити Makefile

**Modify:**

- /home/lex/Projects/tmp/Makefile

Залишити основні команди:

~~~text
make setup
make up
make down
make restart
make ps
make logs
make shell
make artisan CMD="..."
make composer CMD="..."
make npm CMD="..."
make migrate
make test
make prod-build
make prod-up
make prod-down
make prod-logs
make prod-migrate
~~~

Використати змінні:

~~~make
COMPOSE_DEV ?= docker compose -f docker-compose.yml
COMPOSE_PROD ?= docker compose -f docker-compose.prod.yml
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)

export HOST_UID HOST_GID
~~~

make setup має створювати .env лише за його відсутності, створювати vendor і node_modules, виконувати Composer install, npm ci, запускати dev stack і виконувати migrations.

Додати target prepare-dependencies, який root-контейнером змінює права тільки для vendor, node_modules, public/build, public/hot і public/fonts-manifest.dev.json. Він не повинен робити chown -R для всього /var/www/html.

make composer і make npm мають викликати prepare-dependencies перед виконанням. docker compose down -v у Makefile заборонений.

---

### Task 6: Оновити .env.example та .dockerignore

**Modify:**

- /home/lex/Projects/tmp/.env.example
- /home/lex/Projects/tmp/.dockerignore

У .env.example використати для Docker:

~~~text
DB_HOST=db
DB_PORT=3306
DB_FORWARD_PORT=3307
APP_PORT=8000
VITE_FORWARD_PORT=5173
~~~

Не додавати реальні секрети і не перезаписувати існуючий .env.

У .dockerignore виключити:

~~~text
.git
.env
.env.*
vendor
node_modules
public/build
public/hot
public/fonts-manifest.dev.json
storage/logs/*
~~~

Залишити .env.example, якщо він потрібен для build context.

---

### Task 7: Перевірити права та root-owned файли

Виконати:

~~~bash
cd /home/lex/Projects/tmp
make setup
~~~

Перевірити UID:

~~~bash
docker compose run --rm --no-deps app id
docker compose run --rm --no-deps composer id
docker compose run --rm --no-deps node id
~~~

Очікуваний результат — UID/GID host user, наприклад 1000:1000.

Перевірити host-файли:

~~~bash
stat -c '%u:%g %A %n' vendor node_modules
find public/build public -maxdepth 1 \
  \( -name hot -o -name fonts-manifest.dev.json \) \
  -printf '%u:%g %p\n' 2>/dev/null
~~~

Перевірити несподівані root-owned paths:

~~~bash
find . -xdev \( -user root -o -group root \) \
  -not -path './.git/*' \
  -printf '%u:%g %p\n'
~~~

Після make setup у generated/source directories не повинно залишитися несподіваних root:root.

---

### Task 8: Повна dev-перевірка

Виконати:

~~~bash
docker compose config --quiet
git diff --check
make composer CMD="validate --no-check-publish"
make test
docker compose ps
~~~

Перевірити Laravel:

~~~bash
curl --retry 5 --retry-delay 1 \
  -fsS -o /tmp/laravel-home.html \
  -w 'home_http=%{http_code}\n' \
  http://localhost:8000/
~~~

Перевірити Vite:

~~~bash
curl --retry 5 --retry-delay 1 \
  -fsS -o /tmp/vite-client.js \
  -w 'vite_http=%{http_code}\n' \
  http://localhost:5173/@vite/client
~~~

Очікувано:

~~~text
home_http=200
vite_http=200
~~~

Перевірити frontend build від host UID:

~~~bash
make npm CMD="run build"
test -f public/build/manifest.json
stat -c '%u:%g %A %n' public/build/manifest.json
~~~

---

### Task 9: Production image перевірка

Виконати:

~~~bash
docker compose -f docker-compose.prod.yml config --quiet
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps
~~~

Перевірити application container:

~~~bash
docker compose -f docker-compose.prod.yml exec -T app id
docker compose -f docker-compose.prod.yml exec -T app php artisan about
~~~

Перевірити міграції:

~~~bash
docker compose -f docker-compose.prod.yml exec -T app \
  php artisan migrate --force --no-interaction
~~~

Перевірити HTTP через Nginx:

~~~bash
curl --retry 10 --retry-delay 1 \
  -fsS -o /tmp/laravel-prod.html \
  -w 'prod_home_http=%{http_code}\n' \
  http://localhost:8080/
~~~

Перевірити asset manifest в обох контейнерах:

~~~bash
docker compose -f docker-compose.prod.yml exec -T app \
  test -f /var/www/html/public/build/manifest.json

docker compose -f docker-compose.prod.yml exec -T nginx \
  test -f /var/www/html/public/build/manifest.json
~~~

Очікувано:

- PHP image стартує від www-data;
- Nginx бачить public/build;
- production-контейнер не використовує host source mount;
- база доступна через внутрішню Docker network;
- HTTP повертає 200.

---

### Task 10: Фінальний handoff

Перед завершенням виконати:

~~~bash
git status --short
git diff --check
docker compose config --quiet
docker compose -f docker-compose.prod.yml config --quiet
~~~

У фінальному повідомленні вказати змінені файли та команди:

~~~bash
make setup
make up
make prod-build
make prod-up
make prod-migrate
~~~

Також вказати результати перевірок прав UID/GID, Laravel tests, dev HTTP/Vite і production image.

Не виконувати git push без окремого дозволу користувача.
