#!/usr/bin/env bash
# Backup and restore helper for the stacks in this repository.
#
#   scripts/backup_restore.sh backup  [all|nginx|nextcloud|onlyoffice|synapse|vaultwarden]
#   scripts/backup_restore.sh restore <timestamp> [all|nginx|nextcloud|onlyoffice|synapse|vaultwarden]
#
# Each backup lands in backup/<YYYYmmddHHMM>/ (database dumps and tarballs of the
# bind-mounted data directories). Every stack must have its .env in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backup}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
TIMESTAMP="$(date +%Y%m%d%H%M)"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_restore_$TIMESTAMP.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# dc <stack-dir> <docker compose args...>
dc() {
    local stack="$1"; shift
    docker compose -f "$ROOT/$stack/docker-compose.yml" --project-directory "$ROOT/$stack" "$@"
}

# tar_dir <stack-dir> <dir-name> <archive>  (runs in a container so file ownership is preserved)
tar_dir() {
    docker run --rm -v "$ROOT/$1:/src:ro" -v "$(dirname "$3"):/out" alpine \
        tar czf "/out/$(basename "$3")" -C /src "$2"
}

# untar_dir <stack-dir> <archive>
untar_dir() {
    docker run --rm -v "$ROOT/$1:/dst" -v "$(dirname "$2"):/in:ro" alpine \
        tar xzf "/in/$(basename "$2")" -C /dst
}

backup_nginx() {
    local d="$1"
    log "Backing up Nginx Proxy Manager"
    tar_dir nginx-proxy-manager data "$d/nginx_data.tar.gz"
    tar_dir nginx-proxy-manager letsencrypt "$d/nginx_letsencrypt.tar.gz"
}

backup_nextcloud() {
    local d="$1"
    log "Backing up Nextcloud database"
    dc nextcloud-onlyoffice exec -T nextcloud_db \
        sh -c 'exec mariadb-dump --all-databases -uroot -p"$MYSQL_ROOT_PASSWORD"' > "$d/nextcloud_db.sql"
    log "Backing up Nextcloud files"
    tar_dir nextcloud-onlyoffice nextcloud_data "$d/nextcloud_data.tar.gz"
}

backup_onlyoffice() {
    local d="$1"
    log "Backing up OnlyOffice database"
    dc nextcloud-onlyoffice exec -T onlyoffice_db \
        sh -c 'exec pg_dumpall -U "$POSTGRES_USER"' > "$d/onlyoffice_db.sql"
}

backup_synapse() {
    local d="$1"
    log "Backing up Synapse database"
    dc synapse exec -T synapse_db \
        sh -c 'exec pg_dumpall -U "$POSTGRES_USER"' > "$d/synapse_db.sql"
    log "Backing up Synapse config, media and signing key"
    tar_dir synapse data "$d/synapse_data.tar.gz"
}

backup_vaultwarden() {
    local d="$1"
    log "Backing up Vaultwarden"
    tar_dir vaultwarden bitwarden "$d/vaultwarden_data.tar.gz"
}

restore_nginx() {
    local d="$1"
    log "Restoring Nginx Proxy Manager"
    dc nginx-proxy-manager down
    untar_dir nginx-proxy-manager "$d/nginx_data.tar.gz"
    untar_dir nginx-proxy-manager "$d/nginx_letsencrypt.tar.gz"
    dc nginx-proxy-manager up -d
}

restore_nextcloud() {
    local d="$1"
    log "Restoring Nextcloud"
    dc nextcloud-onlyoffice stop nextcloud_app
    untar_dir nextcloud-onlyoffice "$d/nextcloud_data.tar.gz"
    dc nextcloud-onlyoffice up -d nextcloud_db
    sleep 15
    dc nextcloud-onlyoffice exec -T nextcloud_db \
        sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD"' < "$d/nextcloud_db.sql"
    dc nextcloud-onlyoffice up -d nextcloud_app
}

restore_onlyoffice() {
    local d="$1"
    log "Restoring OnlyOffice database"
    dc nextcloud-onlyoffice up -d onlyoffice_db
    sleep 10
    # The role and database already exist on a fresh container, so those errors are expected.
    dc nextcloud-onlyoffice exec -T onlyoffice_db \
        sh -c 'exec psql -U "$POSTGRES_USER" -d postgres' < "$d/onlyoffice_db.sql" || true
    dc nextcloud-onlyoffice restart onlyoffice
}

restore_synapse() {
    local d="$1"
    log "Restoring Synapse"
    dc synapse stop synapse
    untar_dir synapse "$d/synapse_data.tar.gz"
    dc synapse up -d synapse_db
    sleep 10
    dc synapse exec -T synapse_db \
        sh -c 'exec psql -U "$POSTGRES_USER" -d postgres' < "$d/synapse_db.sql" || true
    dc synapse up -d synapse
}

restore_vaultwarden() {
    local d="$1"
    log "Restoring Vaultwarden"
    dc vaultwarden down
    untar_dir vaultwarden "$d/vaultwarden_data.tar.gz"
    dc vaultwarden up -d
}

SERVICES=(nginx nextcloud onlyoffice synapse vaultwarden)

run() {
    local action="$1" dir="$2" target="${3:-all}"
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
        mkdir -p "$dir"
        run backup "$dir" "${2:-all}"
        log "Backup written to $dir"
        ;;
    restore)
        [[ -n "${2:-}" ]] || die "Provide the backup timestamp (a folder name under $BACKUP_DIR)"
        dir="$BACKUP_DIR/$2"
        [[ -d "$dir" ]] || die "No such backup: $dir"
        run restore "$dir" "${3:-all}"
        log "Restore from $dir finished"
        ;;
    *)
        echo "Usage: $0 backup [target] | restore <timestamp> [target]" >&2
        exit 1
        ;;
esac
