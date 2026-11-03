#!/usr/bin/env bash
# Backup and restore helper for the stacks in this repository.
#
#   scripts/backup_restore.sh backup  [all|nginx|nextcloud|onlyoffice|synapse|vaultwarden]
#   scripts/backup_restore.sh restore <timestamp> [all|nginx|nextcloud|onlyoffice|synapse|vaultwarden]
#
# Each backup lands in backup/<YYYYmmddHHMM>/ (database dumps and tarballs of the
# bind-mounted data directories). Every stack must have its .env in place.
set -euo pipefail
# Backups hold secrets (signing keys, config.php, database dumps), keep them private.
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backup}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.24}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
# Docker bind mounts need absolute paths, so resolve a relative BACKUP_DIR.
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
LOG_FILE="$LOG_DIR/backup_restore_$TIMESTAMP.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# Set while a backup is being written, so a failure is reported clearly.
BACKUP_TMP=""
# 1 while Nextcloud is in maintenance mode because of this script.
NEXTCLOUD_MAINTENANCE=0
# 1 while Vaultwarden is stopped because of this script.
VAULTWARDEN_STOPPED=0

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 && -n "$BACKUP_TMP" ]]; then
        log "ERROR: backup failed (exit $rc), incomplete files left in $BACKUP_TMP"
    fi
    # Never leave Nextcloud stuck in maintenance mode when the script stops early.
    if [[ $NEXTCLOUD_MAINTENANCE -eq 1 ]]; then
        if occ maintenance:mode --off >/dev/null 2>&1; then
            log "Nextcloud maintenance mode turned off"
        else
            log "WARNING: could not turn off maintenance mode, run: occ maintenance:mode --off"
        fi
    fi
    # Same for Vaultwarden, it must not stay stopped.
    if [[ $VAULTWARDEN_STOPPED -eq 1 ]]; then
        if dc vaultwarden start vaultwarden >/dev/null 2>&1; then
            log "Vaultwarden started again"
        else
            log "WARNING: Vaultwarden is stopped, run: docker compose -f vaultwarden/docker-compose.yml up -d"
        fi
    fi
}
trap on_exit EXIT

# dc <stack-dir> <docker compose args...>
dc() {
    local stack="$1"; shift
    docker compose -f "$ROOT/$stack/docker-compose.yml" --project-directory "$ROOT/$stack" "$@"
}

preflight() {
    command -v docker >/dev/null || die "docker is not installed"
    docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon (is it running, and are you in the docker group?)"
}

# require_running <stack-dir> <service>
require_running() {
    [[ -n "$(dc "$1" ps --status running --quiet "$2" 2>/dev/null)" ]] \
        || die "Service '$2' is not running in $1, start the stack first"
}

# occ <args...>  runs Nextcloud's CLI as the web server user
occ() {
    dc nextcloud-onlyoffice exec -T -u www-data nextcloud_app php occ "$@"
}

# nextcloud_maintenance on|off
nextcloud_maintenance() {
    if [[ "$1" == on ]]; then NEXTCLOUD_MAINTENANCE=1; fi
    occ maintenance:mode "--$1" >/dev/null
    if [[ "$1" == off ]]; then NEXTCLOUD_MAINTENANCE=0; fi
}

# wait_for <stack-dir> <service> <command run inside the container until it succeeds>
wait_for() {
    local stack="$1" service="$2" check="$3" tries=0
    log "Waiting for $service to be ready"
    until dc "$stack" exec -T "$service" sh -c "$check" >/dev/null 2>&1; do
        tries=$((tries + 1))
        [[ $tries -le 60 ]] || die "Timed out waiting for $service in $stack"
        sleep 2
    done
}

# tar_dir <stack-dir> <dir-name> <archive>  (runs in a container so file ownership is preserved)
tar_dir() {
    docker run --rm -e OWNER="$(id -u):$(id -g)" -v "$ROOT/$1:/src:ro" -v "$(dirname "$3"):/out" "$ALPINE_IMAGE" \
        sh -c 'tar czf "/out/$1" -C /src "$2" && chown "$OWNER" "/out/$1"' _ "$(basename "$3")" "$2"
    gzip -t "$3" || die "Archive failed its integrity check: $3"
}

# untar_dir <stack-dir> <archive> <dir-name>
# Replaces <dir-name> with the archive contents, so files that were created
# after the backup do not survive the restore.
untar_dir() {
    docker run --rm -v "$ROOT/$1:/dst" -v "$(dirname "$2"):/in:ro" "$ALPINE_IMAGE" \
        sh -c '[ -n "$2" ] && rm -rf "/dst/$2" && tar xzf "/in/$1" -C /dst' _ "$(basename "$2")" "$3"
}

# check_dump <file> <text that ends a complete dump>
check_dump() {
    [[ -s "$1" ]] || die "Dump is empty: $1"
    tail -n 5 "$1" | grep -q "$2" || die "Dump looks truncated (missing '$2'): $1"
}

# write_checksums <backup-dir>
write_checksums() {
    (cd "$1" && sha256sum -- * > SHA256SUMS)
}

# verify_checksums <backup-dir>
verify_checksums() {
    [[ -f "$1/SHA256SUMS" ]] || die "No SHA256SUMS in $1, refusing to restore an unverified backup"
    (cd "$1" && sha256sum --check --quiet SHA256SUMS) || die "Checksum mismatch in $1, the backup is damaged"
}

backup_nginx() {
    local d="$1"
    log "Backing up Nginx Proxy Manager"
    tar_dir nginx-proxy-manager data "$d/nginx_data.tar.gz"
    tar_dir nginx-proxy-manager letsencrypt "$d/nginx_letsencrypt.tar.gz"
}

backup_nextcloud() {
    local d="$1"
    require_running nextcloud-onlyoffice nextcloud_db
    require_running nextcloud-onlyoffice nextcloud_app
    # Keep users from writing while the database and the files are copied,
    # otherwise the two can end up out of step.
    log "Turning on Nextcloud maintenance mode"
    nextcloud_maintenance on
    log "Backing up Nextcloud database"
    dc nextcloud-onlyoffice exec -T nextcloud_db \
        sh -c 'exec mariadb-dump --single-transaction --routines --events --databases "$MYSQL_DATABASE" -uroot -p"$MYSQL_ROOT_PASSWORD"' > "$d/nextcloud_db.sql"
    check_dump "$d/nextcloud_db.sql" "Dump completed"
    log "Backing up Nextcloud files"
    tar_dir nextcloud-onlyoffice nextcloud_data "$d/nextcloud_data.tar.gz"
    nextcloud_maintenance off
}

backup_onlyoffice() {
    local d="$1"
    require_running nextcloud-onlyoffice onlyoffice_db
    log "Backing up OnlyOffice database"
    dc nextcloud-onlyoffice exec -T onlyoffice_db \
        sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' > "$d/onlyoffice_db.sql"
    check_dump "$d/onlyoffice_db.sql" "PostgreSQL database dump complete"
}

backup_synapse() {
    local d="$1"
    require_running synapse synapse_db
    log "Backing up Synapse database"
    dc synapse exec -T synapse_db \
        sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' > "$d/synapse_db.sql"
    check_dump "$d/synapse_db.sql" "PostgreSQL database dump complete"
    log "Backing up Synapse config, media and signing key"
    tar_dir synapse data "$d/synapse_data.tar.gz"
}

backup_vaultwarden() {
    local d="$1"
    require_running vaultwarden vaultwarden
    # Copying a SQLite database while it is being written can give a corrupt
    # copy, so Vaultwarden is stopped for the few seconds the archive takes.
    log "Stopping Vaultwarden for a consistent copy"
    VAULTWARDEN_STOPPED=1
    dc vaultwarden stop vaultwarden >/dev/null
    log "Backing up Vaultwarden"
    tar_dir vaultwarden bitwarden "$d/vaultwarden_data.tar.gz"
    dc vaultwarden start vaultwarden >/dev/null
    VAULTWARDEN_STOPPED=0
}

restore_nginx() {
    local d="$1"
    log "Restoring Nginx Proxy Manager"
    dc nginx-proxy-manager down
    untar_dir nginx-proxy-manager "$d/nginx_data.tar.gz" data
    untar_dir nginx-proxy-manager "$d/nginx_letsencrypt.tar.gz" letsencrypt
    dc nginx-proxy-manager up -d
}

restore_nextcloud() {
    local d="$1"
    log "Restoring Nextcloud"
    dc nextcloud-onlyoffice stop nextcloud_app
    untar_dir nextcloud-onlyoffice "$d/nextcloud_data.tar.gz" nextcloud_data
    dc nextcloud-onlyoffice up -d nextcloud_db
    wait_for nextcloud-onlyoffice nextcloud_db 'mariadb-admin ping -uroot -p"$MYSQL_ROOT_PASSWORD"'
    dc nextcloud-onlyoffice exec -T nextcloud_db \
        sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD"' < "$d/nextcloud_db.sql"
    dc nextcloud-onlyoffice up -d nextcloud_app
    log "Waiting for Nextcloud to start"
    local tries=0
    until occ status >/dev/null 2>&1; do
        tries=$((tries + 1))
        [[ $tries -le 60 ]] || die "Timed out waiting for Nextcloud to start"
        sleep 2
    done
    # The files were copied in maintenance mode, so switch it off again and
    # let clients know the data came from a backup so they re-sync.
    occ maintenance:data-fingerprint >/dev/null
    nextcloud_maintenance off
}

restore_onlyoffice() {
    local d="$1"
    log "Restoring OnlyOffice database"
    # The server holds connections to the database, which would block the DROPs below.
    dc nextcloud-onlyoffice stop onlyoffice
    dc nextcloud-onlyoffice up -d onlyoffice_db
    wait_for nextcloud-onlyoffice onlyoffice_db 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    # The dump drops and recreates every table, and runs as one transaction that
    # stops at the first error, so a failed restore changes nothing.
    dc nextcloud-onlyoffice exec -T onlyoffice_db \
        sh -c 'exec psql -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
        < "$d/onlyoffice_db.sql" >/dev/null
    dc nextcloud-onlyoffice up -d onlyoffice
}

restore_synapse() {
    local d="$1"
    log "Restoring Synapse"
    dc synapse stop synapse
    untar_dir synapse "$d/synapse_data.tar.gz" data
    dc synapse up -d synapse_db
    wait_for synapse synapse_db 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
    # The dump drops and recreates every table, and runs as one transaction that
    # stops at the first error, so a failed restore changes nothing.
    dc synapse exec -T synapse_db \
        sh -c 'exec psql -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
        < "$d/synapse_db.sql" >/dev/null
    dc synapse up -d synapse
}

restore_vaultwarden() {
    local d="$1"
    log "Restoring Vaultwarden"
    dc vaultwarden down
    untar_dir vaultwarden "$d/vaultwarden_data.tar.gz" bitwarden
    dc vaultwarden up -d
}

SERVICES=(nginx nextcloud onlyoffice synapse vaultwarden)

run() {
    local action="$1" dir="$2" target="${3:-all}"
    preflight
    if [[ "$target" == all ]]; then
        for s in "${SERVICES[@]}"; do "${action}_$s" "$dir"; done
    elif [[ " ${SERVICES[*]} " == *" $target "* ]]; then
        "${action}_$target" "$dir"
    else
        die "Unknown target '$target' (expected: all ${SERVICES[*]})"
    fi
}

case "${1:-}" in
    backup)
        dir="$BACKUP_DIR/$TIMESTAMP"
        # Write into <timestamp>.partial and only rename once everything succeeded,
        # so a failed run can never be mistaken for a complete backup.
        BACKUP_TMP="$dir.partial"
        mkdir -p "$BACKUP_TMP"
        run backup "$BACKUP_TMP" "${2:-all}"
        write_checksums "$BACKUP_TMP"
        mv "$BACKUP_TMP" "$dir"
        BACKUP_TMP=""
        log "Backup written to $dir"
        ;;
    restore)
        [[ -n "${2:-}" ]] || die "Provide the backup timestamp (a folder name under $BACKUP_DIR)"
        [[ "$2" =~ ^[0-9]+$ ]] || die "Backup name must be a timestamp such as 20261103120000, got '$2'"
        dir="$BACKUP_DIR/$2"
        [[ -d "$dir" ]] || die "No such backup: $dir"
        verify_checksums "$dir"
        run restore "$dir" "${3:-all}"
        log "Restore from $dir finished"
        ;;
    *)
        echo "Usage: $0 backup [target] | restore <timestamp> [target]" >&2
        exit 1
        ;;
esac
