.PHONY: help env up down load-data fetch-data configure simulate verify bootstrap reset tls logs

help:
	@echo "GeoKnight GIS"
	@echo "  make env          Write .env with generated passwords (once)"
	@echo "  make bootstrap    Start, load the sample, and publish the layers"
	@echo "  make up           Start the stack"
	@echo "  make down         Stop the stack, keep data"
	@echo "  make load-data    Load GeoPackages and SQL into PostGIS"
	@echo "  make fetch-data   Download TIGER, 3DEP, and NAIP (or fall back)"
	@echo "  make configure    Publish layers, styles, and accounts"
	@echo "  make simulate     Run the visitor simulation (about 2 minutes)"
	@echo "  make verify       Smoke test HTTPS, access rules, and the dashboard"
	@echo "  make logs         Follow GeoServer logs"
	@echo "  make reset        Stop and delete volumes (destructive)"

env:
	sh scripts/env.sh

tls:
	sh scripts/tls-local.sh

up:
	sh scripts/up.sh

down:
	sh scripts/down.sh

load-data:
	sh scripts/load-data.sh

fetch-data:
	python3 scripts/fetch_data.py --download all || python3 scripts/fetch_data.py --synthetic

configure:
	sh scripts/configure.sh

simulate:
	sh scripts/simulate.sh

verify:
	sh scripts/smoke-test.sh

bootstrap: up load-data configure

logs:
	docker compose logs -f geoserver nginx

reset:
	docker compose --profile sim --profile test --profile letsencrypt --profile oidc down -v
