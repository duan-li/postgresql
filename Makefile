.PHONY: help start stop restart status logs clean clean-all psql

# Colors
GREEN  := $(shell tput -Txterm setaf 2)
YELLOW := $(shell tput -Txterm setaf 3)
WHITE  := $(shell tput -Txterm setaf 7)
RESET  := $(shell tput -Txterm sgr0)

# PostgreSQL connection variables
POSTGRES_USER ?= postgres
POSTGRES_DB ?= vector_db
PGPASSWORD ?= your_secure_password

help: ## Show this help
	@echo ''
	@echo 'Usage:'
	@echo '  ${YELLOW}make${RESET} ${GREEN}<target>${RESET}'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  ${YELLOW}%-15s${GREEN}%s${RESET}\n", $$1, $$2}' $(MAKEFILE_LIST)

start: ## Start the PostgreSQL service
	@echo "${GREEN}Starting PostgreSQL with pgvector...${RESET}"
	@docker compose up -d

stop: ## Stop the PostgreSQL service
	@echo "${YELLOW}Stopping PostgreSQL...${RESET}"
	@docker compose down

restart: stop start ## Restart the PostgreSQL service

status: ## Show container status
	@docker compose ps

logs: ## Show container logs (Ctrl+C to exit)
	@docker compose logs -f

psql: ## Connect to PostgreSQL with psql
	@echo "${GREEN}Connecting to PostgreSQL...${RESET}"
	@PGPASSWORD=${PGPASSWORD} psql -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}

backup: ## Create a database backup
	@mkdir -p backups
	@echo "${GREEN}Creating database backup...${RESET}"
	@docker compose exec -T pgvector pg_dump -U ${POSTGRES_USER} -d ${POSTGRES_DB} > backups/backup_$(shell date +%Y%m%d_%H%M%S).sql
	@echo "Backup created: backups/backup_$(shell date +%Y%m%d_%H%M%S).sql"

clean: ## Remove containers and networks (keeps volumes)
	@echo "${YELLOW}Removing containers and networks...${RESET}"
	@docker compose down

clean-all: clean ## Remove everything including volumes (WARNING: deletes all data!)
	@echo "${YELLOW}Removing volumes...${RESET}"
	@docker volume rm -f postgres_pgvector_data

# Helper targets for common operations
init: start ## Initialize the database (start if not running)
	@echo "${GREEN}Database initialized and ready to use!${RESET}"
	@echo "Run 'make psql' to connect to the database"

setup: ## One-time setup (create .env file if it doesn't exist)
	@if [ ! -f .env ]; then \
		echo "POSTGRES_PASSWORD=$(shell openssl rand -base64 32)" > .env; \
		echo "APP_READONLY_PASSWORD=$(shell openssl rand -base64 32)" >> .env; \
		echo "APP_READWRITE_PASSWORD=$(shell openssl rand -base64 32)" >> .env; \
		echo "${GREEN}Created .env file with random passwords${RESET}"; \
	else \
		echo "${YELLOW}.env file already exists${RESET}"; \
	fi

.DEFAULT_GOAL := help
