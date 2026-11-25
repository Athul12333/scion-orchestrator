# SCION Debian package build and verification targets.
# Included by the repository root Makefile.

# ---------------------------------------------------------------------------
# Upstream SCION Debian packages
# ---------------------------------------------------------------------------
.PHONY: scion-packages
scion-packages: scion-source
	@command -v "$(BAZEL)" >/dev/null 2>&1 || test -x "$(BAZEL)" || { echo "ERROR: Bazel/Bazelisk not found"; exit 1; }
	@echo "==> Building upstream SCION $(SCION_VERSION) Debian packages"
	@cd "$(SCION_DIR)" && SCION_VERSION="$(SCION_PACKAGE_VERSION)" "$(BAZEL)" build //dist:deb_all
	@rm -rf "$(SCION_DIST_DIR)"
	@mkdir -p "$(SCION_DIST_DIR)"
	@set -eu; \
	files="$$(cd "$(SCION_DIR)" && SCION_VERSION="$(SCION_PACKAGE_VERSION)" "$(BAZEL)" cquery '//dist:deb_all' --output=files 2>/dev/null | grep '_amd64\.deb$$')"; \
	test -n "$$files" || { echo "ERROR: no SCION amd64 packages found"; exit 1; }; \
	for f in $$files; do \
		cp "$(SCION_DIR)/$$f" "$(SCION_DIST_DIR)/"; \
	done
	@echo "==> SCION packages collected in $(SCION_DIST_DIR)/"

.PHONY: verify-scion-packages
verify-scion-packages:
	@set -eu; \
	expected="scion-control scion-daemon scion-dispatcher scion-ip-gateway scion-router scion-tools"; \
	count=0; \
	for pkg in $$expected; do \
		f="$$(find "$(SCION_DIST_DIR)" -maxdepth 1 -type f -name "$${pkg}_*_amd64.deb" -print -quit)"; \
		test -n "$$f" || { echo "ERROR: missing $$pkg package"; exit 1; }; \
		test "$$(dpkg-deb -f "$$f" Package)" = "$$pkg" || { echo "ERROR: wrong package name in $$f"; exit 1; }; \
		test "$$(dpkg-deb -f "$$f" Version)" = "$(SCION_PACKAGE_VERSION)" || { echo "ERROR: wrong version in $$f"; exit 1; }; \
		test "$$(dpkg-deb -f "$$f" Architecture)" = "$(ARCH)" || { echo "ERROR: wrong architecture in $$f"; exit 1; }; \
		echo "  verified: $$pkg $(SCION_PACKAGE_VERSION) $(ARCH)"; \
		count=$$((count + 1)); \
	done; \
	actual="$$(find "$(SCION_DIST_DIR)" -maxdepth 1 -type f -name 'scion-*_amd64.deb' | wc -l)"; \
	test "$$actual" -eq "$$count" || { echo "ERROR: expected $$count SCION packages, found $$actual"; exit 1; }; \
	echo "==> SCION package verification passed"

.PHONY: scion-package-check
scion-package-check: scion-packages verify-scion-packages
	@echo "==> SCION build and package verification completed successfully"
