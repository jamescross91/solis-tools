# Every check CI runs, runnable locally. `make` on its own runs them all.
#
# Nothing here needs a Solis inverter: `make demo` starts a fake one.

PYTHON ?= python3
VENV := .venv
BIN := $(VENV)/bin
PORT ?= 5020

.DEFAULT_GOAL := check
.PHONY: check setup test lint format types version swift app demo clean

check: lint format types version test ## Run every check CI runs

setup: $(BIN)/ruff ## Create .venv with runtime and development dependencies

$(BIN)/ruff:
	$(PYTHON) -m venv $(VENV)
	$(BIN)/python -m pip install --quiet --upgrade pip
	$(BIN)/python -m pip install --quiet -e ".[dev]"

test: setup ## Unit and end-to-end tests
	$(BIN)/python -m unittest -v

lint: setup ## ruff check
	$(BIN)/ruff check .

format: setup ## ruff format, verify only
	$(BIN)/ruff format --check .

fix: setup ## ruff format and apply safe lint fixes
	$(BIN)/ruff format .
	$(BIN)/ruff check --fix .

types: setup ## mypy
	$(BIN)/mypy

version: ## Verify every copy of the version agrees
	./scripts/version.py --check

swift: ## Build and test the macOS menu-bar package (macOS only)
	swift test --disable-sandbox --package-path SolisMenuBar

app: ## Build the menu-bar .app bundle (macOS only)
	./scripts/build_menubar_app.sh release

demo: setup ## Run the dashboard against a fake inverter, no hardware needed
	@$(BIN)/python fake_inverter.py --port $(PORT) & \
	trap 'kill %1 2>/dev/null' EXIT; \
	sleep 1; \
	$(BIN)/python solis_poll.py --host 127.0.0.1 --port $(PORT) --pv

clean:
	rm -rf $(VENV) build .mypy_cache .ruff_cache *.egg-info
	rm -rf SolisMenuBar/.build

help: ## List targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'
