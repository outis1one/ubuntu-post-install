.PHONY: help up down build logs clean dev test

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: ## Start the application (production)
	docker-compose up -d

down: ## Stop the application
	docker-compose down

build: ## Build all containers
	docker-compose build

logs: ## Show logs
	docker-compose logs -f

clean: ## Remove all containers, volumes, and data
	docker-compose down -v
	rm -rf data/

dev: ## Start the application (development mode)
	docker-compose -f docker-compose.dev.yml up

test: ## Run tests
	@echo "Tests not yet implemented"

restart: ## Restart the application
	docker-compose restart

ps: ## Show running containers
	docker-compose ps
