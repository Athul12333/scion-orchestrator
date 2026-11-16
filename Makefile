SCION_VERSION := v0.12.0
SCION_REPO    := https://github.com/scionproto/scion.git
SCION_DIR     := dev/scion
RELEASE_DIR   := release

# Orchestrator Debian package settings
VERSION      ?= 0.1.0
ARCH         ?= amd64
DIST_DIR     := dist
PACKAGE      := $(DIST_DIR)/scion-orchestrator_$(VERSION)_$(ARCH).deb
NFPM         ?= $(shell command -v nfpm 2>/dev/null || echo $(HOME)/go/bin/nfpm)

# Development APT repository settings
APT_REPO_DIR ?= $(HOME)/scion-apt-repo
APT_CODENAME ?= scion

# Relative paths inside SCION_DIR to build
SCION_CMDS := \
	scion/cmd/scion \
	scion-pki/cmd/scion-pki \
	router/cmd/router \
	control/cmd/control \
	daemon/cmd/daemon \
	dispatcher/cmd/dispatcher

RELEASE_TARGETS := \
	release-linux-amd64 \
#	release-linux-arm64 \
	release-darwin-amd64 \
	release-darwin-arm64 \
	release-windows-amd64

# ---------------------------------------------------------------------------
# Internal helper — always invoked via $(MAKE) _build-release GOOS=… GOARCH=…
# Using a sub-make avoids the double-$$ escaping that $(define)+$(eval) requires.
# ---------------------------------------------------------------------------
RELEASE_SUBDIR := leaf-as

.PHONY: _build-release
_build-release:
	@echo "==> $(GOOS)/$(GOARCH)"
	@mkdir -p $(RELEASE_DIR)/$(GOOS)_$(GOARCH)/$(RELEASE_SUBDIR)/bin
	@cd $(SCION_DIR) && for cmd in $(SCION_CMDS); do \
		name=$$(basename $$cmd); \
		if [ "$(GOOS)" = "windows" ]; then name="$${name}.exe"; fi; \
		out="$(CURDIR)/$(RELEASE_DIR)/$(GOOS)_$(GOARCH)/$(RELEASE_SUBDIR)/bin/$$name"; \
		echo "  $$cmd -> $$out"; \
		( cd "$$cmd" && CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o "$$out" . ); \
	done
	@if [ "$(GOOS)" = "windows" ]; then \
		CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) \
			go build -o $(RELEASE_DIR)/$(GOOS)_$(GOARCH)/$(RELEASE_SUBDIR)/scion-orchestrator.exe .; \
	else \
		CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) \
			go build -o $(RELEASE_DIR)/$(GOOS)_$(GOARCH)/$(RELEASE_SUBDIR)/scion-orchestrator .; \
	fi
	@cp -r $(RELEASE_DIR)/$(RELEASE_SUBDIR)/config \
		$(RELEASE_DIR)/$(GOOS)_$(GOARCH)/$(RELEASE_SUBDIR)/
	@cd $(RELEASE_DIR)/$(GOOS)_$(GOARCH)/$(RELEASE_SUBDIR) && \
		tar -czf ../../scion-orchestrator_$(SCION_VERSION)_$(GOOS)_$(GOARCH).tar.gz \
			scion-orchestrator* bin config && \
		zip -r   ../../scion-orchestrator_$(SCION_VERSION)_$(GOOS)_$(GOARCH).zip \
			scion-orchestrator* bin config
	@echo "  -> $(RELEASE_DIR)/scion-orchestrator_$(SCION_VERSION)_$(GOOS)_$(GOARCH).{tar.gz,zip}"

# ---------------------------------------------------------------------------
# Per-platform targets
# ---------------------------------------------------------------------------
.PHONY: release-linux-amd64
release-linux-amd64: scion-source
	$(MAKE) _build-release GOOS=linux GOARCH=amd64

.PHONY: release-linux-arm64
release-linux-arm64: scion-source
	$(MAKE) _build-release GOOS=linux GOARCH=arm64

.PHONY: release-darwin-amd64
release-darwin-amd64: scion-source
	$(MAKE) _build-release GOOS=darwin GOARCH=amd64

.PHONY: release-darwin-arm64
release-darwin-arm64: scion-source
	$(MAKE) _build-release GOOS=darwin GOARCH=arm64

.PHONY: release-windows-amd64
release-windows-amd64: scion-source
	$(MAKE) _build-release GOOS=windows GOARCH=amd64

# ---------------------------------------------------------------------------
# Top-level targets
# ---------------------------------------------------------------------------
.PHONY: release
release: $(RELEASE_TARGETS)
	@echo "==> Done. Archives in $(RELEASE_DIR)/"

.PHONY: scion-source
scion-source: $(SCION_DIR)/.git

$(SCION_DIR)/.git:
	mkdir -p dev
	git clone $(SCION_REPO) $(SCION_DIR)
	cd $(SCION_DIR) && git checkout $(SCION_VERSION)

.PHONY: build
build:
	CGO_ENABLED=0 go build -o scion-orchestrator .

.PHONY: build-package
build-package:
	CGO_ENABLED=0 go build -ldflags="-s -w" -o scion-orchestrator .

.PHONY: clean
clean:
	rm -f scion-orchestrator scion-orchestrator.exe

.PHONY: clean-release
clean-release:
	rm -rf $(RELEASE_DIR)

.PHONY: clean-scion
clean-scion:
	rm -rf dev

.PHONY: help
help:
	@echo "Targets:"
	@echo "  release              Build all platforms + create archives"
	@echo "  release-<os>-<arch>  Build a single platform, e.g. release-linux-amd64"
	@echo "  scion-source         Clone SCION $(SCION_VERSION) into $(SCION_DIR)/"
	@echo "  build                Build scion-orchestrator for development"
	@echo "  build-package        Build stripped orchestrator for packaging"
	@echo "  package              Build Debian package with nFPM"
	@echo "  verify-package       Verify generated Debian package"
	@echo "  package-check        Build and verify Debian package"
	@echo "  publish-apt          Build, verify, and publish package to reprepro"
	@echo "  clean                Remove local build artefacts"
	@echo "  clean-release        Remove $(RELEASE_DIR)/"
	@echo "  clean-scion          Remove dev/ (cloned SCION source)"
	@echo ""
	@echo "Platforms: $(RELEASE_TARGETS)"
	@echo "SCION version: $(SCION_VERSION)  (override with SCION_VERSION=...)"

# ---------------------------------------------------------------------------
# Debian packaging with nFPM
# ---------------------------------------------------------------------------
.PHONY: package
package: build-package
	@echo "==> Building Debian package with nFPM"
	@mkdir -p $(DIST_DIR)
	@VERSION=$(VERSION) ARCH=$(ARCH) $(NFPM) package \
		--config nfpm.yaml \
		--packager deb \
		--target $(DIST_DIR)/
	@echo "==> Package written to $(DIST_DIR)/"

.PHONY: verify-package
verify-package:
	@set -eu; \
	contents="$$(mktemp)"; \
	extract="$$(mktemp -d)"; \
	trap 'rm -f "$$contents"; rm -rf "$$extract"' EXIT; \
	test -f "$(PACKAGE)" || { echo "ERROR: $(PACKAGE) does not exist; run 'make package' first"; exit 1; }; \
	test "$$(dpkg-deb -f "$(PACKAGE)" Package)" = "scion-orchestrator"; \
	test "$$(dpkg-deb -f "$(PACKAGE)" Version)" = "$(VERSION)"; \
	test "$$(dpkg-deb -f "$(PACKAGE)" Architecture)" = "$(ARCH)"; \
	dpkg-deb --contents "$(PACKAGE)" > "$$contents"; \
	grep -Fq './usr/bin/scion-orchestrator' "$$contents"; \
	grep -Fq './usr/lib/systemd/system/scion-orchestrator.service' "$$contents"; \
	grep -Fq './usr/share/doc/scion-orchestrator/copyright' "$$contents"; \
	dpkg-deb -x "$(PACKAGE)" "$$extract"; \
	test -x "$$extract/usr/bin/scion-orchestrator"; \
	test "$$(stat -c '%a' "$$extract/usr/bin/scion-orchestrator")" = "755"; \
	test "$$(stat -c '%a' "$$extract/usr/lib/systemd/system/scion-orchestrator.service")" = "644"; \
	cmp -s packaging/scion-orchestrator.service "$$extract/usr/lib/systemd/system/scion-orchestrator.service"; \
	file "$$extract/usr/bin/scion-orchestrator" | grep -Fq 'statically linked'; \
	file "$$extract/usr/bin/scion-orchestrator" | grep -Fq 'stripped'; \
	echo "==> Package verification passed: $(PACKAGE)"

.PHONY: package-check
package-check: package verify-package
	@echo "==> Build and package verification completed successfully"

.PHONY: publish-apt
publish-apt: package-check
	@test -d "$(APT_REPO_DIR)/conf" || { echo "ERROR: reprepro repository not found at $(APT_REPO_DIR)"; exit 1; }
	@command -v reprepro >/dev/null || { echo "ERROR: reprepro is not installed"; exit 1; }
	@echo "==> Publishing $(PACKAGE) to $(APT_REPO_DIR)"
	@cd "$(APT_REPO_DIR)" && reprepro includedeb "$(APT_CODENAME)" "$(CURDIR)/$(PACKAGE)"
	@cd "$(APT_REPO_DIR)" && reprepro listfilter "$(APT_CODENAME)" 'Package (== scion-orchestrator)'
	@echo "==> APT repository publish completed"
