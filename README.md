# Supavisor image

KoedoDB runs [Supavisor](https://github.com/supabase/supavisor) (the Postgres connection pooler) **as upstream publishes it**. Nothing is built or patched here: this directory pins the image, says how KoedoDB runs it, and tests what KoedoDB relies on.

This is not an official Supabase repository, and KoedoDB is not affiliated with Supabase. "Supavisor" and "Supabase" belong to their owners.

## The image

The file `IMAGE` holds the image, by tag and by digest of the multi-architecture index:

```
supabase/supavisor:2.9.13@sha256:07f1a6098ffc04b80263bca4eb5c3e7bd2e03dfd1fc465aa108d7329000a1a4e
```

To update it, change the tag and the digest together (`docker buildx imagetools inspect supabase/supavisor:<tag>`), then run `tests/run.sh`. Check the [release notes](https://github.com/supabase/supavisor/releases) and the [security advisories](https://github.com/supabase/supavisor/security/advisories) first.

The image is large (about 1.6 GB, Debian 12). It runs as root by default; KoedoDB runs it as a non-root user.

## How it is run

```sh
docker run --user 10001:10001 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --env-file sv.env -v ./certs:/certs:ro <IMAGE>
```

The test runs exactly this. Without root, the open-files limit is still raised to 100000 (the entrypoint `limits.sh`, which only needs the container's hard limit to be high enough).

| Variable | Value | Note |
|---|---|---|
| `DATABASE_URL` | `ecto://user:password@host:5432/postgres` | The metadata database (tenants, users). |
| `SECRET_KEY_BASE` | 64 hex characters | `openssl rand -hex 32` |
| `VAULT_ENC_KEY` | **exactly 32 characters** | `openssl rand -hex 16`. It is an AES-256-GCM key: with 31 or 33 characters every tenant write fails with a 500 (`Unknown cipher or invalid key size`). It encrypts the tenants' database passwords in the metadata database. |
| `API_JWT_SECRET` | a random string | Signs the tokens of the management API (port 4000). |
| `METRICS_JWT_SECRET` | a random string | |
| `GLOBAL_DOWNSTREAM_CERT_PATH`, `GLOBAL_DOWNSTREAM_KEY_PATH` | files | The TLS certificate for clients. **They must exist for the migration too** (`/app/bin/migrate` reads the runtime configuration). |
| `ECTO_IPV6`, `ERL_AFLAGS` | `false`, `-proto_dist inet_tcp` | The image defaults to IPv6 (`true`, `-proto_dist inet6_tcp`). Override them where only IPv4 is available. |
| `PROXY_PORT_SESSION`, `PROXY_PORT_TRANSACTION` | `5432`, `6543` | Session mode and transaction mode. |

Run `/app/bin/migrate` once before the server (and after an upgrade). `/api/health` answers 204 slightly before the server has connected to the metadata database; an API call in that moment can fail, so wait for an API call that needs the database (a `GET` of a tenant that does not exist should answer 404).

## Creating a tenant

The management API takes a JWT signed (HS256) with `API_JWT_SECRET`.

```sh
curl -X PUT http://localhost:4000/api/tenants/<external_id> \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{
  "tenant": {
    "db_host": "postgres.p-example-db.svc", "db_port": 5432, "db_database": "app",
    "sni_hostname": "db-example.koedodb.net",
    "enforce_ssl": true, "require_user": false, "upstream_ssl": false,
    "allow_list": ["203.0.113.7/32"],
    "default_pool_size": 5, "default_max_clients": 50,
    "auth_query": "SELECT rolname, rolpassword FROM pg_authid WHERE rolname=$1",
    "users": [{"db_user": "postgres", "db_password": "...", "pool_size": 5, "mode_type": "session", "is_manager": true}]
  }
}'
```

A client chooses the tenant by the host name (`sni_hostname`, matched exactly against the TLS server name) or by a user name with a suffix (`postgres.<external_id>`).

## What the tests check

`tests/run.sh` starts the image with a metadata database and two target databases, and checks:

- it starts as a non-root user with a read-only root file system and no capabilities; the open-files limit is raised;
- the management API refuses a missing token and a token signed with another secret; a tenant can be created, read, changed and deleted;
- the tenant is chosen by the user name suffix and by the host name; two tenants reach two different databases; a wrong password, another tenant's password and an unknown tenant are refused;
- the session port and the transaction port both work, and `SET` lasts for the whole connection on the session port;
- `allow_list` refuses a client outside the list, accepts it once the list is changed (no restart), and accepts IPv4 and IPv6 networks;
- `enforce_ssl` refuses a client without TLS; the certificate verifies against the wildcard name;
- tenants survive a restart, a deleted tenant stays deleted, and the database password is not stored in the clear.

## Things to know

- **`allow_list` defaults to everything** (`["0.0.0.0/0","::/0"]`). Always send it.
- **A tenant has to be created with its `sni_hostname`.** Supavisor caches a failed lookup for 24 hours, keyed by (user, tenant, host name). If a client connects before the tenant has its `sni_hostname`, setting it afterwards is not seen (the test shows it). Set it when the tenant is created.
- **A client may name any database** of the server (the tenant's `db_database` does not limit it). Limit what the role can connect to in PostgreSQL itself (`REVOKE CONNECT ... FROM PUBLIC`).
- The tenants' database passwords are stored encrypted with `VAULT_ENC_KEY`: keep the key as long as the metadata database lives. The metadata database can be rebuilt from the tenants' source of truth.

## License

Copyright 2026 RadarWorks LLC. The files in this repository (`IMAGE`, the tests and this documentation) are licensed under the [Apache License 2.0](LICENSE), the same license as [Supavisor](https://github.com/supabase/supavisor) itself. The Supavisor image is upstream's, under its own license.
