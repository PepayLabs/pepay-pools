PYTHON ?= python3
VENV ?= .venv
ACTIVATE = source $(VENV)/bin/activate

install:
	@test -d $(VENV) || $(PYTHON) -m venv $(VENV)
	@$(ACTIVATE) && pip install -U pip && pip install -r requirements.txt

inventory:
	@$(ACTIVATE) && $(PYTHON) scripts/program_inventory.py --output data/processed/program_inventory.json

sample:
	@$(ACTIVATE) && $(PYTHON) scripts/pipeline.py sample --limit 500 --decode-limit 250

empirics:
	@$(ACTIVATE) && $(PYTHON) scripts/pipeline.py empirics data/processed/tx_samples_enriched.csv

format:
	@$(ACTIVATE) && ruff format scripts

lint:
	@$(ACTIVATE) && ruff check scripts

.PHONY: install inventory sample empirics format lint
