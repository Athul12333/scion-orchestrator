# Combined orchestrator and SCION package workflow.
# Included by the repository root Makefile.

.PHONY: packages-all
packages-all: package-check scion-package-check
	@echo "==> All orchestrator and SCION packages built and verified successfully"
