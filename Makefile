SHELL := /bin/bash
PYTHON ?= $(shell command -v python3 2>/dev/null || command -v python)
.PHONY: help resolve resolve-openssh summary summary-openssh prepare lint

help:
	@echo "可用目标:"
	@echo "  make resolve   查询 nginx 最新稳定版"
	@echo "  make resolve-openssh 查询 OpenSSH 最新版本"
	@echo "  make summary   显示 nginx lockfile 摘要"
	@echo "  make summary-openssh 显示 OpenSSH lockfile 摘要"
	@echo "  make prepare   下载并校验源码到 work/"
	@echo "  make lint      本地执行 bash -n / py_compile / JSON 校验"

resolve:
	@bash scripts/resolve-nginx-version.sh

resolve-openssh:
	@bash scripts/resolve-openssh-version.sh

summary:
	@$(PYTHON) scripts/lockfile.py summary lock/nginx.lock.json

summary-openssh:
	@$(PYTHON) scripts/lockfile.py summary lock/openssh.lock.json

prepare:
	@bash scripts/prepare-sources.sh work lock/nginx.lock.json

lint:
	@set -euo pipefail; \
	for f in $$(git ls-files '*.sh'); do echo "bash -n $$f"; bash -n "$$f"; done; \
	$(PYTHON) -m py_compile scripts/lockfile.py; \
	$(PYTHON) -m json.tool lock/nginx.lock.json >/dev/null; \
	$(PYTHON) -m unittest discover -s tests -v; \
	bash tests/verify-sources-test.sh; \
	echo "lint OK"
