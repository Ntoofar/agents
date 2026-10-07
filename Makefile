.PHONY: plan sync test

PYTHON ?= python3

plan:
	$(PYTHON) sync.py

sync:
	$(PYTHON) sync.py --apply

test:
	$(PYTHON) -B -m unittest discover -s tests -v
