# selfhost-suite

Docker Compose stacks for a small self-hosted collaboration suite. Every web
service sits behind Nginx Proxy Manager on a shared Docker network.

| Stack | Directory | What it runs |
| --- | --- | --- |
| Reverse proxy | `nginx-proxy-manager/` | Nginx Proxy Manager (80, 443, 81, 8448) |
| Files and office | `nextcloud-onlyoffice/` | Nextcloud, MariaDB, Redis, OnlyOffice Document Server, PostgreSQL |
| Chat | `synapse/` | Matrix Synapse and PostgreSQL |
| Passwords | `vaultwarden/` | Vaultwarden |
| Design | `penpot/` | Penpot (frontend, backend, exporter, PostgreSQL, Redis, mail catcher) |

Replace `example.com` with your own domain throughout.

## Setup

1. Create the network every stack shares:

   ```sh
   docker network create nginx_network
   ```

2. In each stack directory copy `.env.example` to `.env` and replace every
   `CHANGE_ME`. Real `.env` files are git-ignored.

3. Start the proxy first, then the other stacks:

   ```sh
   docker compose -f nginx-proxy-manager/docker-compose.yml up -d
   docker compose -f nextcloud-onlyoffice/docker-compose.yml up -d
   ```

4. Open the Nginx Proxy Manager admin UI on port 81 and add a proxy host per
   service (see the ports in each `docker-compose.yml`). Request a Let's Encrypt
   certificate and enable WebSocket support.

## Synapse

Generate the base config once, then merge in `synapse/homeserver.yaml.example`:

```sh
cd synapse
docker run -it --rm -v ./data:/data \
  -e SYNAPSE_SERVER_NAME=matrix.example.com -e SYNAPSE_REPORT_STATS=yes \
  matrixdotorg/synapse:latest generate
```

- Keep the generated `registration_shared_secret`, `macaroon_secret_key` and `form_secret`.
- Synapse uses the bundled PostgreSQL, so set the same password as `POSTGRES_PASSWORD`.
- Federation needs Nginx Proxy Manager to listen on 8448 and proxy to `synapse:8008`.
  Publish 443 and 8448 with a valid certificate on the Matrix hostname.

## Nextcloud and OnlyOffice

- `OVERWRITEPROTOCOL=https` stops mixed-content errors behind the proxy.
- Set the same `JWT_SECRET` in the Nextcloud ONLYOFFICE connector app, otherwise
  documents will not open. It is fixed in `.env` so it survives container restarts.

## Backups

```sh
scripts/backup_restore.sh backup            # everything
scripts/backup_restore.sh backup synapse    # one service
scripts/backup_restore.sh restore 20261103120000 nextcloud
```

Targets: `all` (default), `nginx`, `nextcloud`, `onlyoffice`, `synapse`, `vaultwarden`.

Backups go to `backup/<timestamp>/` and the log to `logs/`. Both are readable only
by you, because they hold database dumps, signing keys and `config.php`.

**How a backup behaves**

- The stacks must be running. The script stops with a clear error otherwise.
- A backup is written to `<timestamp>.partial` and renamed only when every step
  succeeded, so a failed run never looks complete. A `.partial` folder can be deleted.
- Every dump and archive is checked, and `SHA256SUMS` is written. Restore verifies it
  first and refuses a damaged backup.
- Nextcloud is put in maintenance mode while it is backed up, and Vaultwarden is
  stopped for a few seconds, so their data is consistent. Both are brought back
  even if the script fails.
- Set `KEEP_BACKUPS=N` to keep only the newest N backups (default: keep all).
  `BACKUP_DIR`, `LOG_DIR` and `ALPINE_IMAGE` can be overridden the same way.

**How a restore behaves**

- Data folders are replaced, not merged, so files created after the backup are removed.
- Databases are restored in a single transaction and the script stops at the first
  error, leaving the database unchanged.
- Restoring `nginx` restarts the proxy, so your sites are briefly unavailable.

Test a restore on a spare host before you rely on it.

## Upgrading

Image versions are pinned in each stack. Major upgrades of Nextcloud, MariaDB and
PostgreSQL are not interchangeable with older data directories: upgrade one major
version at a time, and dump and restore the databases for PostgreSQL.
