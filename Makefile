.PHONY: plan sync test

plan:
	bash sync.sh

sync:
	bash sync.sh --apply

test:
	bash tests/sync.test.sh
