#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${SCION_APT_REPO:-http://10.0.0.39:8081}"

usage() {
    echo "Usage: $0 [--dry-run|--apply] [--legacy-root PATH]"
}

MODE="--dry-run"
LEGACY_ROOT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            MODE="--dry-run"
            shift
            ;;
        --apply)
            MODE="--apply"
            shift
            ;;
        --legacy-root)
            if [ "$#" -lt 2 ]; then
                echo "[ERROR] --legacy-root requires a path" >&2
                exit 2
            fi
            LEGACY_ROOT="${2%/}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$MODE" in
    --dry-run)
        ;;
    --apply)
        if [ -n "$LEGACY_ROOT" ]; then
            echo "[ERROR] --apply with --legacy-root is not implemented yet." >&2
            echo "[INFO] Use --dry-run while manual-layout migration is under development." >&2
            exit 2
        fi

        if [ "$(id -u)" -ne 0 ]; then
            echo "[ERROR] --apply must be run as root." >&2
            exit 1
        fi

        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
        backup_dir="/root/scion-migration-backup-$timestamp"

        echo "[INFO] APPLY backup stage"
        echo "[INFO] Creating backup: $backup_dir"

        available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
        minimum_kb=102400

        if [ "$available_kb" -lt "$minimum_kb" ]; then
            echo "[ERROR] Less than 100 MB free disk space is available." >&2
            echo "[ERROR] Migration aborted before changing services." >&2
            exit 1
        fi

        mkdir -p "$backup_dir/systemd"

        if [ -d /etc/scion ]; then
            echo "[INFO] Backing up /etc/scion (excluding logs)"

            if ! tar                 --exclude='scion/logs'                 -C /etc                 -cf - scion                 | tar -C "$backup_dir" -xf -; then
                echo "[ERROR] SCION backup failed." >&2
                rm -rf "$backup_dir"
                exit 1
            fi

            echo "[OK] Backed up /etc/scion (logs excluded)"
        else
            echo "[WARNING] /etc/scion does not exist"
        fi

        for path in /etc/systemd/system/scion-*.service; do
            [ -e "$path" ] || continue

            if ! cp -a "$path" "$backup_dir/systemd/"; then
                echo "[ERROR] Failed to back up $path" >&2
                rm -rf "$backup_dir"
                exit 1
            fi

            echo "[OK] Backed up $path"
        done

        echo
        echo "[OK] Backup stage completed."
        echo "[INFO] Backup location: $backup_dir"

        echo
        echo "[INFO] Preparing SCION APT repository"

        apt_source="/etc/apt/sources.list.d/scion.list"

        if ! curl -fsS "$REPO_URL/dists/scion/Release" >/dev/null; then
            echo "[ERROR] Repository unreachable: $REPO_URL" >&2
            exit 1
        fi

        if [ ! -f "$apt_source" ] || ! grep -Fq "$REPO_URL" "$apt_source"; then
            printf 'deb [trusted=yes] %s scion main\n' "$REPO_URL" > "$apt_source"
            echo "[OK] Added APT source: $apt_source"
        else
            echo "[OK] APT source already configured"
        fi

        echo "[INFO] Updating APT metadata"

        if ! apt-get update; then
            echo "[ERROR] apt-get update failed" >&2
            exit 1
        fi

        echo "[OK] APT metadata updated"

        packages=(
            scion-orchestrator
            scion-control
            scion-daemon
            scion-dispatcher
            scion-router
            scion-tools
            scion-ip-gateway
        )

        echo "[INFO] Installing/upgrading required packages"

        if ! DEBIAN_FRONTEND=noninteractive apt-get             -o Dpkg::Options::="--force-confdef"             -o Dpkg::Options::="--force-confold"             install -y "${packages[@]}"; then
            echo "[ERROR] Package installation failed" >&2
            echo "[INFO] Legacy services have not been removed." >&2
            exit 1
        fi

        echo
        echo "[INFO] Verifying installed packages"

        for package in "${packages[@]}"; do
            status="$(dpkg-query -W -f='${db:Status-Status}'                 "$package" 2>/dev/null || true)"

            if [ "$status" != "installed" ]; then
                echo "[ERROR] Required package not installed: $package" >&2
                exit 1
            fi

            version="$(dpkg-query -W -f='${Version}' "$package")"
            echo "[OK] $package $version"
        done

        echo "[OK] All required packages are installed."

        legacy_units=(
            "scion-orchestrator.service"
            "scion-dispatcher.service"
            "scion-daemon.service"
        )

        for path in /etc/systemd/system/scion-control-service-*.service; do
            [ -e "$path" ] || continue
            legacy_units+=("$(basename "$path")")
        done

        for path in /etc/systemd/system/scion-border-router-*.service; do
            [ -e "$path" ] || continue
            legacy_units+=("$(basename "$path")")
        done

        echo
        echo "[INFO] Stopping legacy services"

        for unit in "${legacy_units[@]}"; do
            if systemctl cat "$unit" >/dev/null 2>&1; then
                echo "[STOP] $unit"
                systemctl stop "$unit" || {
                    echo "[ERROR] Failed to stop $unit" >&2
                    exit 1
                }
            else
                echo "[SKIP] $unit not found"
            fi
        done

        echo
        echo "[INFO] Disabling legacy services"

        for unit in "${legacy_units[@]}"; do
            if systemctl cat "$unit" >/dev/null 2>&1; then
                echo "[DISABLE] $unit"
                systemctl disable "$unit" || {
                    echo "[ERROR] Failed to disable $unit" >&2
                    exit 1
                }
            fi
        done

        echo
        echo "[INFO] Verifying legacy services"

        for unit in "${legacy_units[@]}"; do
            if systemctl is-active --quiet "$unit"; then
                echo "[ERROR] $unit is still active" >&2
                exit 1
            else
                echo "[OK] $unit is inactive"
            fi
        done

        echo
        echo "[OK] Legacy services stopped and disabled."

        echo
        echo "[INFO] Removing recognized legacy unit files"

        for unit in "${legacy_units[@]}"; do
            path="/etc/systemd/system/$unit"

            if [ -f "$path" ]; then
                echo "[REMOVE] $path"
                rm -f -- "$path"
            else
                echo "[SKIP] $path not found"
            fi
        done

        echo
        echo "[INFO] Reloading systemd unit definitions"
        systemctl daemon-reload

        echo
        echo "[INFO] Verifying package-provided units"

        for unit in             scion-orchestrator.service             scion-dispatcher.service             scion-daemon.service; do

            fragment="$(systemctl show "$unit"                 --property=FragmentPath                 --value)"

            case "$fragment" in
                /usr/lib/systemd/system/*|/lib/systemd/system/*)
                    echo "[OK] $unit -> $fragment"
                    ;;
                *)
                    echo "[ERROR] Unexpected unit path for $unit: $fragment" >&2
                    exit 1
                    ;;
            esac
        done

        for template in             /lib/systemd/system/scion-control@.service             /lib/systemd/system/scion-router@.service; do

            if [ -f "$template" ]; then
                echo "[OK] Package template exists: $template"
            else
                echo "[ERROR] Package template missing: $template" >&2
                exit 1
            fi
        done

        echo
        echo "[INFO] Verifying obsolete unit names were removed"

        for unit in             scion-control-service-cs1.service             scion-border-router-br1.service; do

            if systemctl cat "$unit" >/dev/null 2>&1; then
                echo "[ERROR] Obsolete unit is still available: $unit" >&2
                exit 1
            else
                echo "[OK] Obsolete unit removed: $unit"
            fi
        done

        echo
        echo "[OK] Package-unit cutover completed."

        echo
        echo "[INFO] Migrating writable control-service databases"

        mkdir -p /var/lib/scion
        chown scion:scion /var/lib/scion

        for config in /etc/scion/cs-*.toml; do
            [ -e "$config" ] || continue

            instance="$(basename "$config" .toml)"
            db_prefix="database${instance}"

            echo "[INFO] Processing control instance: $instance"

            config_backup="${config}.pre-package-migration"

            if [ ! -e "$config_backup" ]; then
                cp -a "$config" "$config_backup"
                echo "[OK] Backed up $config"
            fi

            found_db=false

            for dbfile in /etc/scion/"${db_prefix}"*; do
                [ -e "$dbfile" ] || continue
                found_db=true

                target="/var/lib/scion/$(basename "$dbfile")"

                if [ ! -e "$target" ]; then
                    cp -a "$dbfile" "$target"
                    echo "[OK] Copied $dbfile -> $target"
                else
                    echo "[SKIP] Database already exists: $target"
                fi
            done

            if [ "$found_db" = true ]; then
                find /var/lib/scion -maxdepth 1                     -type f -name "${db_prefix}*"                     -exec chown scion:scion {} +

                sed -i                     "s#/etc/scion/${db_prefix}#/var/lib/scion/${db_prefix}#g"                     "$config"

                echo "[OK] Updated database paths in $config"
            else
                echo "[WARNING] No legacy databases found for $instance"
            fi
        done

        echo
        echo "[INFO] Verifying migrated control database paths"

        for config in /etc/scion/cs-*.toml; do
            [ -e "$config" ] || continue

            if grep -q '/etc/scion/databasecs-' "$config"; then
                echo "[ERROR] Legacy database path remains in $config" >&2
                exit 1
            fi

            grep 'connection' "$config" || true
        done

        echo
        echo "[OK] Control database migration completed."

        echo
        echo "[INFO] Starting package-provided SCION services"

        start_and_check() {
            unit="$1"

            echo "[START] $unit"

            if ! systemctl enable --now "$unit"; then
                echo "[ERROR] Failed to enable/start $unit" >&2
                journalctl -u "$unit" -n 30 --no-pager || true
                exit 1
            fi

            sleep 1

            if systemctl is-active --quiet "$unit"; then
                echo "[OK] $unit is active"
            else
                echo "[ERROR] $unit is not active" >&2
                journalctl -u "$unit" -n 30 --no-pager || true
                exit 1
            fi
        }

        start_and_check "scion-dispatcher.service"
        start_and_check "scion-daemon.service"

        for config in /etc/scion/cs-*.toml; do
            [ -e "$config" ] || continue
            instance="$(basename "$config" .toml)"
            start_and_check "scion-control@${instance}.service"
        done

        for config in /etc/scion/br-*.toml; do
            [ -e "$config" ] || continue
            instance="$(basename "$config" .toml)"
            start_and_check "scion-router@${instance}.service"
        done

        start_and_check "scion-orchestrator.service"

        echo
        echo "[INFO] Checking for legacy home-directory secret references"

        if grep -Rqs '/home/.*/scion-orchestrator/config/client1.secret'             /etc/scion 2>/dev/null; then
            echo "[WARNING] A service configuration still references client1.secret"
            echo "[WARNING] under a user's home directory."
            echo "[WARNING] Move the secret to a service-owned location before"
            echo "[WARNING] relying on CA health checks."
        fi

        echo
        echo "========================================"
        echo " SCION package migration completed"
        echo "========================================"
        echo
        echo "[OK] Package-provided services are active."
        echo "[INFO] Backup location: $backup_dir"
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "[ERROR] Unknown option: $MODE" >&2
        usage >&2
        exit 2
        ;;
esac

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
    "scion-ip-gateway"
)

echo "========================================"
echo " SCION Orchestrator APT Migration Check"
echo "========================================"
echo
echo "[INFO] DRY-RUN mode"
echo "[INFO] No files or services will be modified."

echo
echo "[1/5] Checking existing SCION configuration"

CONFIG_DIR="/etc/scion"

if [ -n "$LEGACY_ROOT" ]; then
    CONFIG_DIR="$LEGACY_ROOT/config"

    echo "[INFO] Legacy root: $LEGACY_ROOT"
    echo "[INFO] Legacy configuration: $CONFIG_DIR"

    if [ ! -d "$LEGACY_ROOT" ]; then
        echo "[ERROR] Legacy root does not exist: $LEGACY_ROOT" >&2
        exit 1
    fi

    if [ ! -d "$CONFIG_DIR" ]; then
        echo "[ERROR] Legacy configuration does not exist: $CONFIG_DIR" >&2
        exit 1
    fi

    if [ -f "$CONFIG_DIR/topology.json" ]; then
        isd_as="$(grep -m1 '"isd_as"' "$CONFIG_DIR/topology.json" | sed -E 's/.*"isd_as"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        echo "[OK] Detected ISD-AS: $isd_as"
    else
        echo "[WARNING] Missing topology: $CONFIG_DIR/topology.json"
    fi

    echo "[INFO] Checking manually started SCION processes"

    for process in dispatcher router control daemon; do
        if pgrep -x "$process" >/dev/null; then
            echo "[FOUND] Running manual process: $process"
        else
            echo "[NOT FOUND] Manual process: $process"
        fi
    done

elif [ -d "$CONFIG_DIR" ]; then
    echo "[OK] $CONFIG_DIR exists"
else
    echo "[WARNING] $CONFIG_DIR does not exist"
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

for config in "$CONFIG_DIR"/cs-*.toml; do
    [ -e "$config" ] || continue
    instance="$(basename "$config" .toml)"
    echo "$config"
    echo "    -> scion-control@${instance}.service"
done

for config in "$CONFIG_DIR"/br-*.toml; do
    [ -e "$config" ] || continue
    instance="$(basename "$config" .toml)"
    echo "$config"
    echo "    -> scion-router@${instance}.service"
done

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

APT_SOURCE="/etc/apt/sources.list.d/scion.list"

if [ -f "$APT_SOURCE" ] && grep -Fq "$REPO_URL" "$APT_SOURCE"; then
    echo "[OK] Repository is configured as an APT source"

    for package in "${PACKAGES[@]}"; do
        candidate="$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')"

        if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
            echo "[MISSING] $package"
        else
            echo "[OK] $package candidate: $candidate"
        fi
    done
else
    echo "[WARNING] Repository is reachable but not configured as an APT source"
    echo "[PLAN] Would add: deb [trusted=yes] $REPO_URL scion main"

    package_index="$(mktemp)"
    trap 'rm -f "$package_index"' EXIT

    curl -fsS         "$REPO_URL/dists/scion/main/binary-amd64/Packages"         -o "$package_index"

    for package in "${PACKAGES[@]}"; do
        if grep -Fxq "Package: $package" "$package_index"; then
            echo "[AVAILABLE] $package"
        else
            echo "[MISSING] $package"
        fi
    done
fi

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
