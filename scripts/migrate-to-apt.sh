#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${SCION_APT_REPO:-http://10.0.0.39:8081}"

usage() {
    echo "Usage: $0 [--dry-run|--apply|--cutover] [--legacy-root PATH] [--stage-dir PATH] [--confirm-cutover]"
}

MODE="--dry-run"
LEGACY_ROOT=""
CUTOVER_STAGE_DIR=""
CONFIRM_CUTOVER=0

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
        --cutover)
            MODE="--cutover"
            shift
            ;;
        --confirm-cutover)
            CONFIRM_CUTOVER=1
            shift
            ;;
        --stage-dir)
            if [ "$#" -lt 2 ]; then
                echo "[ERROR] --stage-dir requires a path" >&2
                exit 2
            fi
            CUTOVER_STAGE_DIR="${2%/}"
            shift 2
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
            if [ "$(id -u)" -ne 0 ]; then
                echo "[ERROR] --apply must be run as root." >&2
                exit 1
            fi

            if [ ! -d "$LEGACY_ROOT/config" ]; then
                echo "[ERROR] Legacy configuration not found: $LEGACY_ROOT/config" >&2
                exit 1
            fi

            timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
            backup_dir="/root/scion-migration-backup-$timestamp"

            echo "[INFO] MANUAL-LAYOUT BACKUP STAGE"
            echo "[INFO] Legacy root: $LEGACY_ROOT"
            echo "[INFO] Creating backup: $backup_dir"

            available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"

            if [ "$available_kb" -lt 102400 ]; then
                echo "[ERROR] Less than 100 MB free disk space." >&2
                exit 1
            fi

            mkdir -p "$backup_dir"

            tar                 --exclude='config/logs'                 -C "$LEGACY_ROOT"                 -cf "$backup_dir/legacy-config.tar"                 config

            tar -tf "$backup_dir/legacy-config.tar" >/dev/null

            if ! tar -tf "$backup_dir/legacy-config.tar" | grep -q '^config/topology.json$'; then
                echo "[ERROR] Backup verification failed: topology.json missing" >&2
                exit 1
            fi

            if ! tar -tf "$backup_dir/legacy-config.tar" | grep -q '^config/crypto/as/ISD1-AS152.pem$'; then
                echo "[ERROR] Backup verification failed: AS certificate missing" >&2
                exit 1
            fi

            echo "[OK] Legacy configuration backup verified."
            echo "[INFO] Backup: $backup_dir/legacy-config.tar"

            stage_dir="/root/scion-migration-stage-$timestamp"
            stage_config="$stage_dir/etc/scion"
            stage_state="$stage_dir/var/lib/scion"

            echo
            echo "[INFO] MANUAL-LAYOUT STAGING STAGE"
            echo "[INFO] Creating staging tree: $stage_dir"

            mkdir -p                 "$stage_config/certs"                 "$stage_config/crypto"                 "$stage_config/keys"                 "$stage_config/secrets"                 "$stage_state"

            echo "[OK] Empty package-ready staging tree created."

            echo "[INFO] Copying runtime configuration"

            install -m 0644 "$LEGACY_ROOT/config/tmp/dispatcher-tmp.toml"                 "$stage_config/dispatcher.toml"

            install -m 0644 "$LEGACY_ROOT/config/tmp/br1-tmp.toml"                 "$stage_config/br-1.toml"

            install -m 0644 "$LEGACY_ROOT/config/tmp/cs1-tmp.toml"                 "$stage_config/cs-1.toml"

            install -m 0644 "$LEGACY_ROOT/config/tmp/sciond-tmp.toml"                 "$stage_config/sciond.toml"

            cp -a "$stage_config/sciond.toml"                 "$stage_config/daemon.toml"

            install -m 0644 "$LEGACY_ROOT/config/topology.json"                 "$stage_config/topology.json"

            install -m 0644 "$LEGACY_ROOT/config/scion-orchestrator.toml"                 "$stage_config/scion-orchestrator.toml"

            echo "[OK] Runtime configuration copied to staging."

            echo "[INFO] Copying certificates, crypto material and keys"

            tar --exclude='*.bak'                 -C "$LEGACY_ROOT/config"                 -cf - certs crypto keys                 | tar -C "$stage_config" -xf -

            echo "[INFO] Copying service secrets"

            install -m 0640                 "$LEGACY_ROOT/config/client1.secret"                 "$stage_config/secrets/client1.secret"

            if [ -f "$LEGACY_ROOT/config/admin.secret" ]; then
                install -m 0640                     "$LEGACY_ROOT/config/admin.secret"                     "$stage_config/secrets/admin.secret"
            fi

            echo "[OK] Crypto material, certificates, keys and secrets copied."

            echo "[INFO] Copying persistent databases"

            if [ -d "$LEGACY_ROOT/config/database" ]; then
                find "$LEGACY_ROOT/config/database"                     -maxdepth 1                     -type f                     -exec cp -a {} "$stage_state/" \;
            fi

            echo "[INFO] Rewriting staged paths"

            find "$stage_config"                 -maxdepth 1                 -type f                 -name '*.toml'                 -exec sed -i                     -e "s#$LEGACY_ROOT/config/database/#/var/lib/scion/#g"                     -e "s#$LEGACY_ROOT/config/#/etc/scion/#g"                     {} +

            sed -i                 's#^shared_secret = "/etc/scion/client1.secret"#shared_secret = "/etc/scion/secrets/client1.secret"#'                 "$stage_config/cs-1.toml"

            sed -i                 -E 's#^[[:space:]]*bin[[:space:]]*=.*#bin = "/usr/bin"#'                 "$stage_config/scion-orchestrator.toml"

            echo "[OK] Database files copied and staged paths rewritten."

            echo "[INFO] Applying staging permissions"

            chown -R root:root "$stage_config" "$stage_state"

            chmod 0755 "$stage_config"
            chmod 0750 "$stage_state"
            chmod 0750 "$stage_config/secrets"

            find "$stage_config/secrets" -type f                 -exec chmod 0640 {} +

            find "$stage_config/crypto/as" -type f -name '*.key'                 -exec chmod 0640 {} +

            find "$stage_config/certs" -type f                 -exec chmod 0644 {} +

            find "$stage_config/crypto" -type f                 \( -name '*.crt' -o -name '*.pem' -o -name '*.tmpl' \)                 -exec chmod 0644 {} +

            find "$stage_config/keys" -type f -name '*.key'                 -exec chmod 0640 {} +

            find "$stage_config" -maxdepth 1 -type f                 -exec chmod 0644 {} +

            if getent passwd scion >/dev/null &&
               getent group scion >/dev/null; then
                chown -R scion:scion "$stage_state"
                chown root:scion "$stage_config/secrets"

                find "$stage_config/secrets" -type f                     -exec chown root:scion {} +

                find "$stage_config/crypto/as" -type f -name '*.key'                     -exec chown root:scion {} +

                find "$stage_config/keys" -type f -name '*.key'                     -exec chown root:scion {} +

                echo "[OK] Applied scion service ownership."
            else
                echo "[INFO] scion account is not installed yet."
                echo "[INFO] Staged files remain root-owned until package installation."
            fi

            echo "[INFO] Validating staging tree"

            required_files=(
                "$stage_config/topology.json"
                "$stage_config/dispatcher.toml"
                "$stage_config/daemon.toml"
                "$stage_config/cs-1.toml"
                "$stage_config/br-1.toml"
                "$stage_config/scion-orchestrator.toml"
                "$stage_config/secrets/client1.secret"
                "$stage_config/crypto/as/cp-as.key"
            )

            for required in "${required_files[@]}"; do
                if [ ! -f "$required" ]; then
                    echo "[ERROR] Missing staged file: $required" >&2
                    exit 1
                fi
            done

            if grep -Rqs "$LEGACY_ROOT" "$stage_config"; then
                echo "[ERROR] Legacy path remains in staged configuration:" >&2
                grep -Rsn "$LEGACY_ROOT" "$stage_config" >&2 || true
                exit 1
            fi

            as_chain="$(find "$stage_config/crypto/as"                 -maxdepth 1 -type f -name 'ISD*-AS*.pem' | head -1)"

            if [ -z "$as_chain" ]; then
                echo "[ERROR] No AS certificate chain found in staging" >&2
                exit 1
            fi

            cert_hash="$(openssl x509                 -in "$as_chain"                 -pubkey -noout |
                openssl pkey -pubin -outform DER 2>/dev/null |
                sha256sum |
                awk '{print $1}')"

            key_hash="$(openssl pkey                 -in "$stage_config/crypto/as/cp-as.key"                 -pubout -outform DER 2>/dev/null |
                sha256sum |
                awk '{print $1}')"

            if [ "$cert_hash" != "$key_hash" ]; then
                echo "[ERROR] AS certificate/private-key mismatch" >&2
                exit 1
            fi

            echo "[OK] AS certificate and private key match."
            echo "[OK] Package-ready staging tree validated."
            echo "[INFO] Staging tree: $stage_dir"
            echo
            echo "[OK] Staging phase completed."

            echo
            echo "[INFO] PACKAGE INSTALL PREPARATION"

            policy_file="/usr/sbin/policy-rc.d"
            apt_source="/etc/apt/sources.list.d/scion.list"

            if [ -e "$policy_file" ]; then
                echo "[ERROR] Existing $policy_file detected." >&2
                echo "[ERROR] Refusing to overwrite an existing service-start policy." >&2
                exit 1
            fi

            if ! curl -fsS "$REPO_URL/dists/scion/Release" >/dev/null; then
                echo "[ERROR] Repository unreachable: $REPO_URL" >&2
                exit 1
            fi

            echo "[OK] Repository reachable: $REPO_URL"
            echo "[OK] No existing policy-rc.d detected."

            echo
            echo "[INFO] INSTALLING PACKAGES WITH SERVICE STARTS BLOCKED"

            cat > "$policy_file" <<'EOF'
#!/bin/sh
exit 101
EOF
            chmod 0755 "$policy_file"

            cleanup_policy() {
                rm -f "$policy_file"
            }

            trap cleanup_policy EXIT

            printf 'deb [trusted=yes] %s scion main
' "$REPO_URL"                 > "$apt_source"

            echo "[INFO] Updating APT metadata"

            if ! apt-get update; then
                echo "[ERROR] apt-get update failed." >&2
                exit 1
            fi

            packages=(
                scion-orchestrator
                scion-control
                scion-daemon
                scion-dispatcher
                scion-router
                scion-tools
                scion-ip-gateway
            )

            echo "[INFO] Installing SCION packages"

            if ! DEBIAN_FRONTEND=noninteractive apt-get                 -o Dpkg::Options::="--force-confdef"                 -o Dpkg::Options::="--force-confold"                 install -y "${packages[@]}"; then

                echo "[ERROR] Package installation failed." >&2
                exit 1
            fi

            cleanup_policy
            trap - EXIT

            if [ -e "$policy_file" ]; then
                echo "[ERROR] Temporary policy-rc.d was not removed." >&2
                exit 1
            fi

            if ! getent passwd scion >/dev/null ||
               ! getent group scion >/dev/null; then
                echo "[ERROR] Package installation did not create scion account." >&2
                exit 1
            fi

            echo "[OK] scion service account exists."

            for package in "${packages[@]}"; do
                status="$(dpkg-query -W -f='${db:Status-Status}'                     "$package" 2>/dev/null || true)"

                if [ "$status" != "installed" ]; then
                    echo "[ERROR] Package not installed: $package" >&2
                    exit 1
                fi

                version="$(dpkg-query -W -f='${Version}' "$package")"
                echo "[OK] $package $version"
            done

            echo
            echo "[STOP] Package-install stage completed."
            echo "[INFO] Legacy manual SCION processes have NOT been stopped."
            echo "[INFO] Staged configuration has NOT been installed into /etc/scion."
            exit 0
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
    --cutover)
        if [ "$(id -u)" -ne 0 ]; then
            echo "[ERROR] --cutover must be run as root." >&2
            exit 1
        fi

        if [ -z "$LEGACY_ROOT" ]; then
            echo "[ERROR] --cutover requires --legacy-root PATH." >&2
            exit 1
        fi

        if [ "$CONFIRM_CUTOVER" -ne 1 ]; then
            echo "[STOP] Cutover confirmation is missing." >&2
            echo "[INFO] Re-run with --confirm-cutover only after final review." >&2
            exit 1
        fi

        if [ ! -d "$LEGACY_ROOT/config" ]; then
            echo "[ERROR] Legacy configuration not found: $LEGACY_ROOT/config" >&2
            exit 1
        fi

        legacy_config="$LEGACY_ROOT/config"
        legacy_database="$legacy_config/database"

        echo "[INFO] MANUAL-LAYOUT CUTOVER PREFLIGHT"
        echo "[INFO] Legacy root: $LEGACY_ROOT"

        if ! getent passwd scion >/dev/null ||
           ! getent group scion >/dev/null; then
            echo "[ERROR] Required scion account is missing." >&2
            exit 1
        fi

        echo "[OK] scion service account exists."

        packages=(
            scion-orchestrator
            scion-control
            scion-daemon
            scion-dispatcher
            scion-router
            scion-tools
            scion-ip-gateway
        )

        for package in "${packages[@]}"; do
            status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"

            if [ "$status" != "installed" ]; then
                echo "[ERROR] Required package not installed: $package" >&2
                exit 1
            fi

            version="$(dpkg-query -W -f='${Version}' "$package")"
            echo "[OK] $package $version"
        done

        if [ -z "$CUTOVER_STAGE_DIR" ]; then
            echo "[ERROR] --cutover requires --stage-dir PATH." >&2
            exit 1
        fi

        stage_dir="$CUTOVER_STAGE_DIR"

        case "$stage_dir" in
            /root/scion-migration-stage-*)
                ;;
            *)
                echo "[ERROR] Invalid cutover staging path: $stage_dir" >&2
                echo "[ERROR] Expected /root/scion-migration-stage-*" >&2
                exit 1
                ;;
        esac

        stage_config="$stage_dir/etc/scion"
        stage_state="$stage_dir/var/lib/scion"

        if [ ! -d "$stage_config" ] || [ ! -d "$stage_state" ]; then
            echo "[ERROR] Incomplete staging tree: $stage_dir" >&2
            exit 1
        fi

        echo "[OK] Selected staging tree: $stage_dir"

        required_stage_files=(
            "$stage_config/topology.json"
            "$stage_config/dispatcher.toml"
            "$stage_config/daemon.toml"
            "$stage_config/cs-1.toml"
            "$stage_config/br-1.toml"
            "$stage_config/scion-orchestrator.toml"
            "$stage_config/secrets/client1.secret"
            "$stage_config/crypto/as/cp-as.key"
        )

        for required_file in "${required_stage_files[@]}"; do
            if [ ! -f "$required_file" ]; then
                echo "[ERROR] Missing staged file: $required_file" >&2
                exit 1
            fi
        done

        if grep -RqsF "$LEGACY_ROOT" "$stage_config"; then
            echo "[ERROR] Legacy-root reference remains in staging." >&2
            grep -RsnF "$LEGACY_ROOT" "$stage_config" >&2 || true
            exit 1
        fi

        as_chain="$(
            find "$stage_config/crypto/as"                 -maxdepth 1                 -type f                 -name 'ISD*-AS*.pem' |
            head -1
        )"

        if [ -z "$as_chain" ] || [ ! -f "$as_chain" ]; then
            echo "[ERROR] Staged AS certificate chain is missing." >&2
            exit 1
        fi

        cert_hash="$(
            openssl x509 -in "$as_chain" -pubkey -noout 2>/dev/null |
            openssl pkey -pubin -outform DER 2>/dev/null |
            sha256sum |
            awk '{print $1}'
        )"

        key_hash="$(
            openssl pkey                 -in "$stage_config/crypto/as/cp-as.key"                 -pubout -outform DER 2>/dev/null |
            sha256sum |
            awk '{print $1}'
        )"

        if [ "$cert_hash" != "$key_hash" ]; then
            echo "[ERROR] Staged AS certificate/private-key mismatch." >&2
            exit 1
        fi

        if [ ! -d "$legacy_database" ]; then
            echo "[ERROR] Legacy database directory missing: $legacy_database" >&2
            exit 1
        fi

        echo "[OK] Required staged files exist."
        echo "[OK] No legacy-root references remain."
        echo "[OK] Staged AS certificate/private key match."
        echo "[OK] Legacy database source exists."

        required_units=(
            scion-orchestrator.service
            scion-dispatcher.service
            scion-daemon.service
            scion-control@.service
            scion-router@.service
        )

        for unit in "${required_units[@]}"; do
            if ! systemctl cat "$unit" >/dev/null 2>&1; then
                echo "[ERROR] Packaged systemd unit missing: $unit" >&2
                exit 1
            fi
        done

        echo "[OK] Required packaged systemd units exist."

        target_units=(
            scion-orchestrator.service
            scion-dispatcher.service
            scion-daemon.service
            scion-control@cs-1.service
            scion-router@br-1.service
        )

        for unit in "${target_units[@]}"; do
            if systemctl is-active --quiet "$unit"; then
                echo "[ERROR] Packaged service already active: $unit" >&2
                exit 1
            fi
        done

        echo "[OK] Packaged target services are inactive."

        process_specs=(
            "dispatcher|$legacy_config/tmp/dispatcher-tmp.toml"
            "router|$legacy_config/tmp/br1-tmp.toml"
            "control|$legacy_config/tmp/cs1-tmp.toml"
            "daemon|$legacy_config/tmp/sciond-tmp.toml"
        )

        legacy_names=()
        legacy_configs=()
        legacy_pids=()

        for spec in "${process_specs[@]}"; do
            process_name="${spec%%|*}"
            process_config="${spec#*|}"
            matches=()

            while read -r pid; do
                [ -n "$pid" ] || continue

                args="$(ps -p "$pid" -o args= 2>/dev/null || true)"

                case "$args" in
                    *"--config $process_config"*)
                        matches+=("$pid")
                        ;;
                esac
            done < <(pgrep -x "$process_name" || true)

            if [ "${#matches[@]}" -ne 1 ]; then
                echo "[ERROR] Expected exactly one $process_name process for:" >&2
                echo "[ERROR] $process_config" >&2
                echo "[ERROR] Matches found: ${#matches[@]}" >&2
                exit 1
            fi

            legacy_names+=("$process_name")
            legacy_configs+=("$process_config")
            legacy_pids+=("${matches[0]}")
            echo "[OK] $process_name PID ${matches[0]} -> $process_config"
        done

        stop_legacy_processes() {
            local index
            local process_name
            local process_config
            local pid
            local current_args
            local attempt

            echo "[INFO] Stopping verified legacy SCION processes"

            # Reverse order: daemon, control, router, dispatcher.
            for ((index=${#legacy_pids[@]} - 1; index >= 0; index--)); do
                process_name="${legacy_names[$index]}"
                process_config="${legacy_configs[$index]}"
                pid="${legacy_pids[$index]}"

                if ! kill -0 "$pid" 2>/dev/null; then
                    echo "[ERROR] $process_name PID $pid disappeared before shutdown." >&2
                    return 1
                fi

                current_args="$(ps -p "$pid" -o args= 2>/dev/null || true)"

                case "$current_args" in
                    *"--config $process_config"*)
                        ;;
                    *)
                        echo "[ERROR] PID identity changed before shutdown: $pid" >&2
                        echo "[ERROR] Expected config: $process_config" >&2
                        return 1
                        ;;
                esac

                echo "[INFO] Sending SIGTERM to $process_name PID $pid"
                kill -TERM "$pid"

                for attempt in $(seq 1 30); do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        echo "[OK] $process_name PID $pid stopped."
                        break
                    fi

                    sleep 1
                done

                if kill -0 "$pid" 2>/dev/null; then
                    echo "[ERROR] $process_name PID $pid did not stop after 30 seconds." >&2
                    echo "[ERROR] Refusing to send SIGKILL automatically." >&2
                    return 1
                fi
            done

            for pid in "${legacy_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    echo "[ERROR] Legacy PID remains alive after shutdown: $pid" >&2
                    return 1
                fi
            done

            echo "[INFO] Verifying no legacy SCION runtime remains"

            for spec in "${process_specs[@]}"; do
                process_name="${spec%%|*}"
                process_config="${spec#*|}"
                remaining=0

                while read -r pid; do
                    [ -n "$pid" ] || continue

                    current_args="$(ps -p "$pid" -o args= 2>/dev/null || true)"

                    case "$current_args" in
                        *"--config $process_config"*)
                            echo "[ERROR] Legacy runtime remains: $process_name PID $pid" >&2
                            remaining=1
                            ;;
                    esac
                done < <(pgrep -x "$process_name" || true)

                if [ "$remaining" -ne 0 ]; then
                    return 1
                fi
            done

            echo "[OK] All verified legacy SCION processes stopped."
            echo "[OK] No matching legacy SCION runtime remains."
        }

        restart_legacy_runtime() {
            local restart_specs
            local spec
            local process_name
            local process_config
            local output_file
            local pid
            local matches

            restart_specs=(
                "dispatcher|$legacy_config/tmp/dispatcher-tmp.toml|/tmp/as152-dispatcher-start.log"
                "daemon|$legacy_config/tmp/sciond-tmp.toml|/tmp/as152-daemon-start.log"
                "control|$legacy_config/tmp/cs1-tmp.toml|/tmp/as152-control-start.log"
                "router|$legacy_config/tmp/br1-tmp.toml|/tmp/as152-router-start.log"
            )

            echo "[INFO] Restoring legacy SCION runtime"

            for spec in "${restart_specs[@]}"; do
                process_name="${spec%%|*}"
                spec="${spec#*|}"
                process_config="${spec%%|*}"
                output_file="${spec#*|}"
                matches=0

                if [ ! -x "$LEGACY_ROOT/bin/$process_name" ]; then
                    echo "[ERROR] Legacy binary missing: $LEGACY_ROOT/bin/$process_name" >&2
                    return 1
                fi

                if [ ! -f "$process_config" ]; then
                    echo "[ERROR] Legacy config missing: $process_config" >&2
                    return 1
                fi

                while read -r pid; do
                    [ -n "$pid" ] || continue

                    current_args="$(ps -p "$pid" -o args= 2>/dev/null || true)"

                    case "$current_args" in
                        *"--config $process_config"*)
                            matches=$((matches + 1))
                            ;;
                    esac
                done < <(pgrep -x "$process_name" || true)

                if [ "$matches" -gt 1 ]; then
                    echo "[ERROR] Multiple legacy $process_name processes already exist." >&2
                    echo "[ERROR] Matching processes: $matches" >&2
                    return 1
                fi

                if [ "$matches" -eq 1 ]; then
                    echo "[OK] Legacy $process_name is already running."
                    continue
                fi

                (
                    cd "$LEGACY_ROOT"
                    nohup "./bin/$process_name"                         --config "$process_config"                         >>"$output_file" 2>&1 </dev/null &
                )

                echo "[INFO] Started legacy $process_name"
            done

            sleep 3

            for spec in "${restart_specs[@]}"; do
                process_name="${spec%%|*}"
                spec="${spec#*|}"
                process_config="${spec%%|*}"
                matches=0

                while read -r pid; do
                    [ -n "$pid" ] || continue

                    current_args="$(ps -p "$pid" -o args= 2>/dev/null || true)"

                    case "$current_args" in
                        *"--config $process_config"*)
                            matches=$((matches + 1))
                            echo "[OK] Legacy $process_name PID $pid"
                            ;;
                    esac
                done < <(pgrep -x "$process_name" || true)

                if [ "$matches" -ne 1 ]; then
                    echo "[ERROR] Legacy restart verification failed: $process_name" >&2
                    echo "[ERROR] Expected one matching process, found $matches" >&2
                    echo "[INFO] Startup output: ${spec#*|}" >&2
                    return 1
                fi
            done

            echo "[OK] Legacy SCION runtime restarted and verified."
        }

        stop_packaged_services() {
            local units
            local unit
            local failure=0

            units=(
                scion-orchestrator.service
                scion-daemon.service
                scion-control@cs-1.service
                scion-router@br-1.service
                scion-dispatcher.service
            )

            echo "[INFO] Stopping package-managed SCION services"

            for unit in "${units[@]}"; do
                if systemctl is-active --quiet "$unit"; then
                    echo "[INFO] Stopping $unit"

                    if ! systemctl stop "$unit"; then
                        echo "[ERROR] Failed to stop $unit" >&2
                        systemctl status "$unit" --no-pager -l >&2 || true
                        failure=1
                    fi
                fi

                if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                    echo "[INFO] Disabling $unit"

                    if ! systemctl disable "$unit"; then
                        echo "[ERROR] Failed to disable $unit" >&2
                        failure=1
                    fi
                fi
            done

            systemctl reset-failed "${units[@]}" || true

            for unit in "${units[@]}"; do
                if systemctl is-active --quiet "$unit"; then
                    echo "[ERROR] Packaged service remains active: $unit" >&2
                    failure=1
                fi
            done

            if [ "$failure" -ne 0 ]; then
                return 1
            fi

            echo "[OK] Package-managed SCION services are stopped and disabled."
        }

        start_packaged_services() {
            local units
            local unit
            local attempt

            units=(
                scion-dispatcher.service
                scion-router@br-1.service
                scion-control@cs-1.service
                scion-daemon.service
                scion-orchestrator.service
            )

            echo "[INFO] Starting package-managed SCION services"

            systemctl daemon-reload
            systemctl reset-failed "${units[@]}" || true

            for unit in "${units[@]}"; do
                echo "[INFO] Enabling and starting $unit"

                if ! systemctl enable --now "$unit"; then
                    echo "[ERROR] Failed to start $unit" >&2
                    systemctl status "$unit" --no-pager -l >&2 || true
                    journalctl -u "$unit" -n 80 --no-pager >&2 || true
                    return 1
                fi

                for attempt in $(seq 1 15); do
                    if systemctl is-active --quiet "$unit"; then
                        break
                    fi

                    sleep 1
                done

                if ! systemctl is-active --quiet "$unit"; then
                    echo "[ERROR] Service is not active: $unit" >&2
                    systemctl status "$unit" --no-pager -l >&2 || true
                    journalctl -u "$unit" -n 80 --no-pager >&2 || true
                    return 1
                fi

                sleep 2

                if ! systemctl is-active --quiet "$unit"; then
                    echo "[ERROR] Service exited after initial startup: $unit" >&2
                    systemctl status "$unit" --no-pager -l >&2 || true
                    journalctl -u "$unit" -n 80 --no-pager >&2 || true
                    return 1
                fi

                echo "[OK] $unit is active."
            done

            for unit in "${units[@]}"; do
                if ! systemctl is-enabled --quiet "$unit"; then
                    echo "[ERROR] Service is not enabled: $unit" >&2
                    return 1
                fi
            done

            echo "[OK] All package-managed SCION services are active and enabled."
        }

        cutover_backup=""

        backup_cutover_targets() {
            cutover_backup="/root/scion-cutover-backup-$(date -u +%Y%m%dT%H%M%SZ)"

            echo "[INFO] Backing up current package-managed targets"
            mkdir -p "$cutover_backup"

            if [ -d /etc/scion ]; then
                tar -C /etc -cf "$cutover_backup/etc-scion.tar" scion
                tar -tf "$cutover_backup/etc-scion.tar" >/dev/null
                touch "$cutover_backup/had-etc-scion"
                echo "[OK] Backed up /etc/scion"
            fi

            if [ -d /var/lib/scion ]; then
                tar -C /var/lib -cf "$cutover_backup/var-lib-scion.tar" scion
                tar -tf "$cutover_backup/var-lib-scion.tar" >/dev/null
                touch "$cutover_backup/had-var-lib-scion"
                echo "[OK] Backed up /var/lib/scion"
            fi

            printf '%s\n' "$stage_dir" > "$cutover_backup/staging-tree"
            printf '%s\n' "$LEGACY_ROOT" > "$cutover_backup/legacy-root"

            echo "[OK] Cutover target backup verified."
            echo "[INFO] Cutover backup: $cutover_backup"
        }

        restore_cutover_targets() {
            echo "[INFO] Restoring package-managed targets from cutover backup"

            if [ -z "$cutover_backup" ] || [ ! -d "$cutover_backup" ]; then
                echo "[ERROR] Cutover backup directory is unavailable." >&2
                return 1
            fi

            if [ -e "$cutover_backup/had-etc-scion" ]; then
                if [ ! -f "$cutover_backup/etc-scion.tar" ]; then
                    echo "[ERROR] Missing /etc/scion backup archive." >&2
                    return 1
                fi

                tar -tf "$cutover_backup/etc-scion.tar" >/dev/null
            fi

            if [ -e "$cutover_backup/had-var-lib-scion" ]; then
                if [ ! -f "$cutover_backup/var-lib-scion.tar" ]; then
                    echo "[ERROR] Missing /var/lib/scion backup archive." >&2
                    return 1
                fi

                tar -tf "$cutover_backup/var-lib-scion.tar" >/dev/null
            fi

            rm -rf                 /etc/scion                 /var/lib/scion                 /etc/scion.cutover-new                 /var/lib/scion.cutover-new

            if [ -d "$cutover_backup/pre-cutover-etc-scion" ]; then
                mv "$cutover_backup/pre-cutover-etc-scion" /etc/scion
                echo "[OK] Restored preserved /etc/scion"
            elif [ -e "$cutover_backup/had-etc-scion" ]; then
                tar -C /etc -xf "$cutover_backup/etc-scion.tar"
                echo "[OK] Restored /etc/scion from archive"
            fi

            if [ -d "$cutover_backup/pre-cutover-var-lib-scion" ]; then
                mv "$cutover_backup/pre-cutover-var-lib-scion" /var/lib/scion
                echo "[OK] Restored preserved /var/lib/scion"
            elif [ -e "$cutover_backup/had-var-lib-scion" ]; then
                tar -C /var/lib -xf "$cutover_backup/var-lib-scion.tar"
                echo "[OK] Restored /var/lib/scion from archive"
            fi

            systemctl daemon-reload

            echo "[OK] Package-managed targets restored from backup."
            echo "[INFO] Restored backup: $cutover_backup"
        }

        install_staged_targets() {
            local config_tmp="/etc/scion.cutover-new"
            local state_tmp="/var/lib/scion.cutover-new"

            echo "[INFO] Preparing package-managed SCION targets"

            if lsof +D /etc/scion 2>/dev/null | grep -q .; then
                echo "[ERROR] A process still has files open under /etc/scion." >&2
                lsof +D /etc/scion >&2 || true
                return 1
            fi

            if lsof +D /var/lib/scion 2>/dev/null | grep -q .; then
                echo "[ERROR] A process still has files open under /var/lib/scion." >&2
                lsof +D /var/lib/scion >&2 || true
                return 1
            fi

            rm -rf "$config_tmp" "$state_tmp"
            mkdir -p "$config_tmp" "$state_tmp"

            cp -a "$stage_config"/. "$config_tmp"/
            cp -a "$stage_state"/. "$state_tmp"/

            chown -R root:root "$config_tmp"
            chmod 0755 "$config_tmp"

            find "$config_tmp" -type d -exec chmod 0755 {} +
            find "$config_tmp" -type f -exec chmod 0644 {} +

            if [ -d "$config_tmp/secrets" ]; then
                chown root:scion "$config_tmp/secrets"
                chmod 0750 "$config_tmp/secrets"

                find "$config_tmp/secrets"                     -maxdepth 1                     -type f                     -exec chown root:scion {} +                     -exec chmod 0640 {} +
            fi

            if [ -f "$config_tmp/secrets/admin.secret" ]; then
                chown root:root "$config_tmp/secrets/admin.secret"
                chmod 0600 "$config_tmp/secrets/admin.secret"
            fi

            if [ -d "$config_tmp/crypto/as" ]; then
                chown root:scion "$config_tmp/crypto/as"
                chmod 0750 "$config_tmp/crypto/as"

                find "$config_tmp/crypto/as"                     -maxdepth 1                     -type f                     -name '*.key'                     -exec chown root:scion {} +                     -exec chmod 0640 {} +
            fi

            if [ -d "$config_tmp/keys" ]; then
                chown root:scion "$config_tmp/keys"
                chmod 0750 "$config_tmp/keys"

                find "$config_tmp/keys"                     -maxdepth 1                     -type f                     -name '*.key'                     -exec chown root:scion {} +                     -exec chmod 0640 {} +
            fi

            if [ -d "$config_tmp/crypto/ca" ]; then
                chown root:root "$config_tmp/crypto/ca"
                chmod 0700 "$config_tmp/crypto/ca"

                find "$config_tmp/crypto/ca"                     -maxdepth 1                     -type f                     -name '*.key'                     -exec chown root:root {} +                     -exec chmod 0600 {} +
            fi

            chown -R scion:scion "$state_tmp"
            chmod 0750 "$state_tmp"
            find "$state_tmp" -maxdepth 1 -type f -exec chmod 0640 {} +

            required_target_files=(
                "$config_tmp/topology.json"
                "$config_tmp/dispatcher.toml"
                "$config_tmp/daemon.toml"
                "$config_tmp/cs-1.toml"
                "$config_tmp/br-1.toml"
                "$config_tmp/scion-orchestrator.toml"
                "$config_tmp/secrets/client1.secret"
                "$config_tmp/crypto/as/cp-as.key"
            )

            for required_file in "${required_target_files[@]}"; do
                if [ ! -f "$required_file" ]; then
                    echo "[ERROR] Prepared target is missing: $required_file" >&2
                    return 1
                fi
            done

            if grep -RqsF "$LEGACY_ROOT" "$config_tmp"; then
                echo "[ERROR] Legacy-root reference exists in prepared target." >&2
                grep -RsnF "$LEGACY_ROOT" "$config_tmp" >&2 || true
                return 1
            fi

            if [ "$(stat -c '%U:%G %a' "$config_tmp/secrets/client1.secret")" !=                  "root:scion 640" ]; then
                echo "[ERROR] Invalid client1.secret ownership or mode." >&2
                return 1
            fi

            if [ "$(stat -c '%U:%G %a' "$config_tmp/crypto/as/cp-as.key")" !=                  "root:scion 640" ]; then
                echo "[ERROR] Invalid AS-key ownership or mode." >&2
                return 1
            fi

            if [ "$(stat -c '%U:%G %a' "$state_tmp")" !=                  "scion:scion 750" ]; then
                echo "[ERROR] Invalid state-directory ownership or mode." >&2
                return 1
            fi

            if [ -z "$cutover_backup" ] || [ ! -d "$cutover_backup" ]; then
                echo "[ERROR] Cutover backup is unavailable before target switch." >&2
                return 1
            fi

            if [ -e "$cutover_backup/pre-cutover-etc-scion" ] ||
               [ -e "$cutover_backup/pre-cutover-var-lib-scion" ]; then
                echo "[ERROR] Preserved target directory already exists in backup." >&2
                return 1
            fi

            if [ -d /etc/scion ]; then
                mv /etc/scion "$cutover_backup/pre-cutover-etc-scion"
            fi

            if [ -d /var/lib/scion ]; then
                mv /var/lib/scion "$cutover_backup/pre-cutover-var-lib-scion"
            fi

            if ! mv "$config_tmp" /etc/scion; then
                echo "[ERROR] Failed to activate staged /etc/scion." >&2
                return 1
            fi

            if ! mv "$state_tmp" /var/lib/scion; then
                echo "[ERROR] Failed to activate staged /var/lib/scion." >&2
                return 1
            fi

            echo "[OK] Staged configuration installed into /etc/scion."
            echo "[OK] Final database state installed into /var/lib/scion."
        }

        snapshot_final_databases() {
            local snapshot_tmp
            local source_manifest
            local snapshot_manifest
            local source_count
            local snapshot_count

            echo "[INFO] Creating final stopped database snapshot"

            if lsof +D "$legacy_database" 2>/dev/null | grep -q .; then
                echo "[ERROR] A process still has legacy database files open." >&2
                lsof +D "$legacy_database" >&2 || true
                return 1
            fi

            source_count="$(
                find "$legacy_database"                     -maxdepth 1                     -type f |
                wc -l
            )"

            if [ "$source_count" -eq 0 ]; then
                echo "[ERROR] Legacy database directory is empty." >&2
                return 1
            fi

            snapshot_tmp="${stage_state}.final-tmp"
            source_manifest="${stage_dir}/legacy-database.sha256"
            snapshot_manifest="${stage_dir}/staged-database.sha256"

            rm -rf "$snapshot_tmp"
            mkdir -p "$snapshot_tmp"

            find "$legacy_database"                 -maxdepth 1                 -type f                 -exec cp -a {} "$snapshot_tmp/" \;

            snapshot_count="$(
                find "$snapshot_tmp"                     -maxdepth 1                     -type f |
                wc -l
            )"

            if [ "$snapshot_count" -ne "$source_count" ]; then
                echo "[ERROR] Database snapshot file count mismatch." >&2
                rm -rf "$snapshot_tmp"
                return 1
            fi

            (
                cd "$legacy_database"
                find . -maxdepth 1 -type f -print0 |
                    sort -z |
                    xargs -0 sha256sum
            ) > "$source_manifest"

            (
                cd "$snapshot_tmp"
                find . -maxdepth 1 -type f -print0 |
                    sort -z |
                    xargs -0 sha256sum
            ) > "$snapshot_manifest"

            if ! cmp -s "$source_manifest" "$snapshot_manifest"; then
                echo "[ERROR] Final database snapshot hash verification failed." >&2
                diff -u "$source_manifest" "$snapshot_manifest" >&2 || true
                rm -rf "$snapshot_tmp"
                return 1
            fi

            rm -rf "$stage_state"
            mv "$snapshot_tmp" "$stage_state"

            chown -R scion:scion "$stage_state"
            chmod 0750 "$stage_state"
            find "$stage_state" -maxdepth 1 -type f -exec chmod 0640 {} +

            echo "[OK] Final database snapshot verified."
            echo "[OK] Database files: $snapshot_count"
            echo "[INFO] Source manifest: $source_manifest"
            echo "[INFO] Staged manifest: $snapshot_manifest"
        }

        recover_legacy_runtime() {
            local recovery_failure=0

            echo
            echo "[WARNING] Cutover failed. Starting recovery."

            if ! stop_packaged_services; then
                echo "[ERROR] Failed to fully stop packaged services during recovery." >&2
                recovery_failure=1
            fi

            if ! restore_cutover_targets; then
                echo "[ERROR] Failed to restore package-managed targets." >&2
                echo "[ERROR] Legacy runtime will NOT be restarted automatically." >&2
                recovery_failure=1
            else
                if ! restart_legacy_runtime; then
                    echo "[ERROR] Failed to restore the complete legacy runtime." >&2
                    recovery_failure=1
                fi
            fi

            if [ "$recovery_failure" -ne 0 ]; then
                echo "[ERROR] Automatic recovery was incomplete." >&2

                if [ -n "$cutover_backup" ]; then
                    echo "[INFO] Recovery backup: $cutover_backup" >&2
                fi

                return 1
            fi

            echo "[OK] Legacy runtime recovery completed."
            echo "[INFO] Recovery backup: $cutover_backup"
        }

        echo
        echo "[OK] Complete manual-layout cutover preflight passed."
        echo "[INFO] Staging tree: $stage_dir"
        echo "[INFO] Verified legacy PIDs: ${legacy_pids[*]}"

        echo
        echo "[INFO] BEGINNING CONFIRMED MANUAL-LAYOUT CUTOVER"

        if ! backup_cutover_targets; then
            echo "[ERROR] Cutover target backup failed." >&2
            echo "[ERROR] Legacy runtime has NOT been stopped." >&2
            exit 1
        fi

        if ! stop_legacy_processes; then
            echo "[ERROR] Legacy shutdown failed." >&2
            recover_legacy_runtime || true
            exit 1
        fi

        if ! snapshot_final_databases; then
            echo "[ERROR] Final database snapshot failed." >&2
            recover_legacy_runtime || true
            exit 1
        fi

        if ! install_staged_targets; then
            echo "[ERROR] Target installation failed." >&2
            recover_legacy_runtime || true
            exit 1
        fi

        if ! start_packaged_services; then
            echo "[ERROR] Packaged service startup failed." >&2
            recover_legacy_runtime || true
            exit 1
        fi

        echo
        echo "========================================"
        echo " Manual-layout SCION cutover completed"
        echo "========================================"
        echo
        echo "[OK] Legacy manual runtime has been replaced."
        echo "[OK] Package-managed SCION services are active."
        echo "[INFO] Cutover backup: $cutover_backup"
        echo "[INFO] Staging tree: $stage_dir"
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
