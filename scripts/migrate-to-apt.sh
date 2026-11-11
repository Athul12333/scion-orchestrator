#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${SCION_APT_REPO:-http://10.0.0.39:8080}"

OLD_UNITS=(
    "scion-orchestrator.service"
    "scion-dispatcher.service"
    "scion-daemon.service"
    "scion-control-service-cs1.service"
    "scion-border-router-br1.service"
)

PACKAGES=(
    "scion-orchestrator"
    "scion-control"
    "scion-daemon"
    "scion-dispatcher"
    "scion-router"
    "scion-tools"
)

echo "========================================"
echo " SCION Orchestrator APT Migration Check"
echo "========================================"
echo
echo "[INFO] DRY-RUN mode"
echo "[INFO] No files or services will be modified."

echo
echo "[1/5] Checking existing SCION configuration"

if [ -d /etc/scion ]; then
    echo "[OK] /etc/scion exists"
else
    echo "[WARNING] /etc/scion does not exist"
fi

echo
echo "[2/5] Checking legacy systemd units"

for unit in "${OLD_UNITS[@]}"; do
    path="/etc/systemd/system/$unit"

    if [ -e "$path" ]; then
        echo "[FOUND] $path"
    else
        echo "[NOT FOUND] $path"
    fi
done

echo
echo "[3/5] Planned service migration"

echo "scion-orchestrator.service"
echo "    -> packaged scion-orchestrator.service"

echo "scion-dispatcher.service"
echo "    -> packaged scion-dispatcher.service"

echo "scion-daemon.service"
echo "    -> packaged scion-daemon.service"

echo "scion-control-service-cs1.service"
echo "    -> scion-control@cs-1.service"

echo "scion-border-router-br1.service"
echo "    -> scion-router@br-1.service"

echo
echo "[4/5] Checking APT repository"

if curl -fsS "$REPO_URL/dists/scion/Release" >/dev/null; then
    echo "[OK] Repository reachable: $REPO_URL"
else
    echo "[ERROR] Repository unreachable: $REPO_URL"
    exit 1
fi

echo
echo "[5/5] Checking required packages"

for package in "${PACKAGES[@]}"; do
    candidate="$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')"

    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        echo "[MISSING] $package"
    else
        echo "[OK] $package candidate: $candidate"
    fi
done

echo
echo "========================================"
echo " Migration dry-run completed"
echo "========================================"
echo
echo "No changes were made."
echo
echo "A real migration would:"
echo "  1. Back up /etc/scion and legacy systemd units"
echo "  2. Stop and disable legacy services"
echo "  3. Remove recognized legacy unit files"
echo "  4. Reload systemd"
echo "  5. Configure the SCION APT repository"
echo "  6. Install SCION and SCION-Orchestrator packages"
echo "  7. Map legacy service names to packaged units"
echo "  8. Validate configuration before starting services"
