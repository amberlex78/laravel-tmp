COMPOSE ?= docker compose
CMD ?=
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)

export HOST_UID HOST_GID

.PHONY: help setup build up down restart ps logs shell artisan composer npm key vendor-permissions migrate fresh test

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: build ## Install dependencies, start containers, generate key, and migrate
	@if [ ! -f .env ]; then cp .env.example .env; fi
	$(COMPOSE) run --rm --no-deps composer install --no-interaction --prefer-dist
	$(MAKE) vendor-permissions
	$(COMPOSE) run --rm --no-deps node npm ci --ignore-scripts
	$(COMPOSE) up -d
	$(MAKE) key
	$(COMPOSE) exec -T app php artisan migrate --force

build: ## Build the PHP image
	$(COMPOSE) build

up: ## Start the development stack in the background
	$(COMPOSE) up -d

down: ## Stop and remove development containers
	$(COMPOSE) down

restart: ## Restart the development stack
	$(COMPOSE) restart

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Follow logs from all services
	$(COMPOSE) logs -f --tail=100

shell: ## Open a shell in the PHP container
	$(COMPOSE) exec app bash

key: ## Generate APP_KEY only when it is not set
	@if ! grep -qE '^APP_KEY=.+$$' .env 2>/dev/null; then $(COMPOSE) exec -T app php artisan key:generate --force; else echo "APP_KEY is already set"; fi

vendor-permissions: ## Make the Composer volume writable by the host user
	$(COMPOSE) run --rm --no-deps --user root --entrypoint sh composer -lc 'chown -R $(HOST_UID):$(HOST_GID) /var/www/html/vendor'

artisan: ## Run an Artisan command, for example: make artisan CMD="about"
	$(COMPOSE) exec -T app php artisan $(CMD)

composer: ## Run Composer, for example: make composer CMD="update"
	$(COMPOSE) run --rm --no-deps composer $(CMD)
	$(MAKE) vendor-permissions

npm: ## Run npm, for example: make npm CMD="run build"
	$(COMPOSE) run --rm --no-deps node npm $(CMD)

migrate: ## Run pending database migrations
	$(COMPOSE) exec -T app php artisan migrate --force

fresh: ## Drop and recreate the database, then run seeders
	$(COMPOSE) exec -T app php artisan migrate:fresh --seed --force

test: ## Run the Laravel test suite
	$(COMPOSE) exec -T app php artisan test --compact
