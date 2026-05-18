SHELL := /usr/bin/env bash

SCRIPT := setup-tor-guard-relay.sh
SHELLCHECK_EXCLUDES := SC2034,SC2178

.PHONY: check syntax shellcheck test smoke render-screenshots

check: syntax shellcheck test smoke

syntax:
	bash -n $(SCRIPT)

shellcheck:
	shellcheck -S warning -e $(SHELLCHECK_EXCLUDES) $(SCRIPT) tests/test-functions.bash

test:
	bash tests/test-functions.bash
	python3 -m py_compile scripts/render-readme-screenshots.py

smoke:
	./$(SCRIPT) --version
	./$(SCRIPT) --help >/tmp/tor-relay-setup-help.txt
	grep -Fq -- '--dry-run' /tmp/tor-relay-setup-help.txt

render-screenshots:
	python3 scripts/render-readme-screenshots.py /tmp/tor-relay-dry-run.txt
