IMAGE     ?= sakiladb/oracle:latest
CONTAINER ?= sakiladb-oracle
PORT      ?= 1521
PDB       ?= SAKILA
USER      ?= sakila
PASSWORD  ?= p_ssW0rd

.PHONY: help build convert-data run stop restart logs sqlplus shell test clean rebuild

help:
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the image as $(IMAGE)
	docker build -t $(IMAGE) .

convert-data: ## Regenerate 2-oracle-sakila-data.sql from the vendored MySQL dump
	python3 convert_data.py mysql-sakila-data.sql 2-oracle-sakila-data.sql

run: ## Start $(CONTAINER) in the background on :$(PORT)
	docker run --rm -d --name $(CONTAINER) -p $(PORT):1521 $(IMAGE)

stop: ## Stop and remove $(CONTAINER)
	-docker stop $(CONTAINER)

restart: stop run ## Stop, then run

logs: ## Tail $(CONTAINER) logs
	docker logs -f $(CONTAINER)

sqlplus: ## Open sqlplus inside $(CONTAINER) as $(USER)@$(PDB)
	docker exec -it $(CONTAINER) sqlplus $(USER)/$(PASSWORD)@//localhost:1521/$(PDB)

shell: ## bash into $(CONTAINER)
	docker exec -it $(CONTAINER) bash

test: ## Smoke-check row counts against the running $(CONTAINER)
	@docker exec $(CONTAINER) sh -c "echo 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0;\nSELECT COUNT(*) FROM actor;\nSELECT COUNT(*) FROM film;\nSELECT COUNT(*) FROM rental;' | sqlplus -S $(USER)/$(PASSWORD)@//localhost:1521/$(PDB)"

clean: ## Remove $(IMAGE) and any dangling builder cache
	-docker rmi $(IMAGE)
	docker builder prune -f

rebuild: clean build ## Clean, then build
