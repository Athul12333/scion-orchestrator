# APT repository publishing targets.
# Included by the repository root Makefile.

.PHONY: publish-apt
publish-apt: package-check
	@test -d "$(APT_REPO_DIR)/conf" || { echo "ERROR: reprepro repository not found at $(APT_REPO_DIR)"; exit 1; }
	@command -v reprepro >/dev/null || { echo "ERROR: reprepro is not installed"; exit 1; }
	@echo "==> Publishing $(PACKAGE) to $(APT_REPO_DIR)"
	@cd "$(APT_REPO_DIR)" && reprepro includedeb "$(APT_CODENAME)" "$(CURDIR)/$(PACKAGE)"
	@cd "$(APT_REPO_DIR)" && reprepro listfilter "$(APT_CODENAME)" 'Package (== scion-orchestrator)'
	@echo "==> APT repository publish completed"

.PHONY: publish-all
publish-all: packages-all
	@test -d "$(APT_REPO_DIR)/conf" || { echo "ERROR: reprepro repository not found at $(APT_REPO_DIR)"; exit 1; }
	@command -v reprepro >/dev/null || { echo "ERROR: reprepro is not installed"; exit 1; }
	@echo "==> Safely publishing all verified packages to $(APT_REPO_DIR)"
	@./scripts/publish-deb.sh "$(APT_REPO_DIR)" "$(APT_CODENAME)" "$(CURDIR)/$(PACKAGE)"
	@set -eu; \
	for f in "$(SCION_DIST_DIR)"/*.deb; do \
		./scripts/publish-deb.sh "$(APT_REPO_DIR)" "$(APT_CODENAME)" "$(CURDIR)/$$f"; \
	done
	@echo "==> Repository contents:"
	@cd "$(APT_REPO_DIR)" && reprepro list "$(APT_CODENAME)"
	@echo "==> Safe publication completed successfully"
