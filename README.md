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
scripts/backup_restore.sh restore 202611031200 nextcloud
```

Backups go to `backup/<timestamp>/` and the log to `logs/`.

## Upgrading

Image versions are pinned in each stack. Major upgrades of Nextcloud, MariaDB and
PostgreSQL are not interchangeable with older data directories: upgrade one major
version at a time, and dump and restore the databases for PostgreSQL.
