#!/bin/bash
# Runs the pinned Supavisor image (the file IMAGE) in Docker, as the Pod will run it: a non-root user, a read-only root file system, no capabilities. It checks the
# behaviour KoedoDB relies on, against a metadata database and two target databases. Nothing is built: the image is upstream's, used as it is.
#
#   tests/run.sh        # about a minute; ends with "ALL OK"
#
# Needs Docker, python3 and openssl. It uses no secrets: every password is made up here, and the certificate is made for the run.
#
# What is NOT checked here: nothing about Kubernetes (hostNetwork, NetworkPolicy, the Host's firewall), and a client IP seen through the Host's network.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$(tr -d '[:space:]' < "$here/IMAGE")"
PG="postgres:18.6-trixie@sha256:5a5a84b19854a9ffaa54082c166ff4ec27473a361e496e5ea167f298f2da9722"
run="kbsv$$"
net="${run}-net"
# Under $HOME: the Docker daemon has to see it (a temporary directory may be private to the shell that made it).
work="${HOME}/.${run}"; rm -rf "$work"; mkdir -p "$work"; chmod 755 "$work"
cleanup() { docker rm -f "${run}-meta" "${run}-db1" "${run}-db2" "${run}-sv" >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1; rm -rf "$work"; }
trap '[ -n "${KEEP:-}" ] || cleanup' EXIT
fail=0
check() {
  local out; out="$(eval "$2" 2>&1)"; local rc=$?
  if [ $rc = 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; fail=1; [ -n "${DEBUG:-}" ] && echo "      -> $(printf %s "$out" | head -20 | cut -c1-260)"; fi
}
note() { echo "note: $1"; }

api_secret="api-$(openssl rand -hex 12)"
cat > "$work/sv.env" <<ENV
DATABASE_URL=ecto://postgres:metapw@${run}-meta:5432/postgres
SECRET_KEY_BASE=$(openssl rand -hex 32)
VAULT_ENC_KEY=$(openssl rand -hex 16)
API_JWT_SECRET=${api_secret}
METRICS_JWT_SECRET=metrics-$(openssl rand -hex 12)
ECTO_IPV6=false
ERL_AFLAGS=-proto_dist inet_tcp
REGION=test
GLOBAL_DOWNSTREAM_CERT_PATH=/certs/cert.pem
GLOBAL_DOWNSTREAM_KEY_PATH=/certs/key.pem
ENV
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=*.koedodb.test" \
  -addext "subjectAltName=DNS:*.koedodb.test" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
chmod 644 "$work/key.pem" "$work/cert.pem"

echo "== $IMAGE"
docker network create "$net" >/dev/null
docker run -d --name "${run}-meta" --network "$net" -e POSTGRES_PASSWORD=metapw "$PG" >/dev/null
docker run -d --name "${run}-db1" --network "$net" -e POSTGRES_PASSWORD=pw1 -e POSTGRES_DB=app "$PG" >/dev/null
docker run -d --name "${run}-db2" --network "$net" -e POSTGRES_PASSWORD=pw2 -e POSTGRES_DB=app "$PG" >/dev/null
for c in meta db1 db2; do
  for _ in $(seq 1 60); do docker exec "${run}-$c" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
done
sleep 3
docker exec "${run}-db1" psql -U postgres -d app -qc "create table who(name text); insert into who values ('one')"
docker exec "${run}-db2" psql -U postgres -d app -qc "create table who(name text); insert into who values ('two')"

echo "== the metadata schema, then the server (non-root, read-only root, no capabilities)"
# The runtime configuration reads the certificate paths even for the migration, so the certificate is mounted for it too.
docker run --rm --network "$net" --user 10001:10001 --env-file "$work/sv.env" -v "$work:/certs:ro" --entrypoint /app/bin/migrate "$IMAGE" >/dev/null 2>&1
check "the migration made the metadata tables" "[ \"\$(docker exec ${run}-meta psql -U postgres -Atc \"select count(*) from pg_tables where schemaname='_supavisor'\")\" -ge 4 ]"
jwt() { python3 - "$1" <<'PY'
import hmac, hashlib, base64, json, sys, time
b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); p = b(json.dumps({"role": "admin", "exp": int(time.time()) + 3600}).encode())
print((h + b"." + p + b"." + b(hmac.new(sys.argv[1].encode(), h + b"." + p, hashlib.sha256).digest())).decode())
PY
}
jwt_for_wait() { jwt "$api_secret"; }
start_sv() {
  docker run -d --name "${run}-sv" --network "$net" --network-alias db-sni1.koedodb.test --network-alias db-late.koedodb.test --user 10001:10001 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --env-file "$work/sv.env" -v "$work:/certs:ro" "$IMAGE" >/dev/null
  # /api/health answers 204 before the server has connected to the metadata database, and an API call in that moment is a 500. So wait for an API
  # call that needs the database to answer properly (404: no such tenant).
  for _ in $(seq 1 60); do
    if [ "$(docker exec "${run}-sv" curl -s -o /dev/null -w '%{http_code}' localhost:4000/api/health 2>/dev/null)" = 204 ] &&
       [ "$(docker exec "${run}-sv" curl -s -o /dev/null -w '%{http_code}' localhost:4000/api/tenants/readiness-probe -H "Authorization: Bearer $(jwt_for_wait)" 2>/dev/null)" = 404 ]; then return 0; fi
    sleep 1
  done
  return 1
}
check "it starts and answers /api/health" "start_sv"
check "it runs as a non-root user" "[ \"\$(docker exec ${run}-sv id -u)\" = 10001 ]"
check "the open-files limit is raised to 100000 (limits.sh) for the server process, without root" "docker exec ${run}-sv sh -c 'grep -l \"Max open files *100000\" /proc/[0-9]*/limits' | grep -q limits"

TOKEN="$(jwt "$api_secret")"
api() {  # method path [body-file] -> prints the HTTP status, and leaves the body in $work/out
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    docker exec -i "${run}-sv" sh -c "curl -s -o /tmp/out -w '%{http_code}' -X $method localhost:4000$path -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -d @-" < "$body"
  else
    docker exec "${run}-sv" sh -c "curl -s -o /tmp/out -w '%{http_code}' -X $method localhost:4000$path -H 'Authorization: Bearer $TOKEN'"
  fi
  docker exec "${run}-sv" cat /tmp/out > "$work/out" 2>/dev/null
}
tenant() {  # external_id db_host password allow_list_json enforce_ssl
  cat > "$work/tenant.json" <<JSON
{"tenant":{"db_host":"$2","db_port":5432,"db_database":"app","require_user":false,"upstream_ssl":false,"enforce_ssl":$5,
 "default_pool_size":5,"default_max_clients":50,"allow_list":$4,
 "auth_query":"SELECT rolname, rolpassword FROM pg_authid WHERE rolname=\$1",
 "users":[{"db_user":"postgres","db_password":"$3","pool_size":5,"mode_type":"session","is_manager":true}]}}
JSON
  if [ -n "${6:-}" ]; then
    python3 - "$work/tenant.json" "$6" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["tenant"]["sni_hostname"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))
PY
  fi
  api PUT "/api/tenants/$1" "$work/tenant.json"
}

echo "== the management API"
check "no token: refused" "[ \"\$(docker exec ${run}-sv curl -s -o /dev/null -w '%{http_code}' -X PUT localhost:4000/api/tenants/x -H 'Content-Type: application/json' -d '{}')\" -ge 401 ]"
check "a token signed with another secret: refused" "[ \"\$(docker exec ${run}-sv curl -s -o /dev/null -w '%{http_code}' localhost:4000/api/tenants/x -H 'Authorization: Bearer $(jwt wrong-secret)')\" -ge 401 ]"
check "a tenant is created (the server reads the target's version from it)" "s=\$(tenant db-one ${run}-db1 pw1 '[\"0.0.0.0/0\"]' false); echo \"status=\$s body=\$(head -c 200 $work/out)\"; [ \$s = 500 ] \&\& docker logs ${run}-sv 2>\&1 | tail -12 | cut -c1-260; [ \$s = 201 ] || [ \$s = 200 ]"
check "and read back" "[ \"\$(api GET /api/tenants/db-one)\" = 200 ] && grep -q '\"external_id\":\"db-one\"' $work/out"
check "a second tenant, on the other database" "s=\$(tenant db-two ${run}-db2 pw2 '[\"0.0.0.0/0\"]' false); [ \$s = 201 ] || [ \$s = 200 ]"
note "a tenant created without allow_list is open to the world: the default is [\"0.0.0.0/0\",\"::/0\"], so KoedoDB must always send allow_list"
default_allow_list() {
  # The same body as the other tenants, with the one key left out.
  python3 - "$work/tenant.json" "$work/t0.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["tenant"].pop("allow_list", None); json.dump(d, open(sys.argv[2], "w"))
PY
  local s; s="$(api PUT /api/tenants/db-default "$work/t0.json")"
  [ "$s" = 201 ] || [ "$s" = 200 ] || { echo "PUT status=$s $(head -c 200 "$work/out")"; return 1; }
  s="$(api GET /api/tenants/db-default)"
  grep -q '"allow_list":\["0.0.0.0/0","::/0"\]' "$work/out" || { echo "GET status=$s $(head -c 300 "$work/out")"; return 1; }
}
check "the default allow_list is open (the reason for the note above)" "default_allow_list"

client() {  # user password port sslmode host [dbname] -> the answer of: select name from who
  docker run --rm --network "$net" -v "$work:/certs:ro" -e PGPASSWORD="$2" "$PG" \
    psql "host=${5:-${run}-sv} port=$3 sslmode=$4 sslrootcert=/certs/cert.pem user=$1 dbname=${6:-app} connect_timeout=8" -Atc "select name from who" 2>&1 | head -3
}
# says <regex> <client args>: the client's answer matches the regex. The answer is kept first: with pipefail, a grep -q that stops early would fail the pipeline.
says() { local pat="$1"; shift; local out; out="$(client "$@")"; grep -qiE "$pat" <<<"$out"; }
echo "== choosing the tenant"
check "by the user name postgres.<tenant>: the first database" "[ \"\$(client postgres.db-one pw1 5432 require)\" = one ]"
check "by the user name: the second database (the tenants are separate)" "[ \"\$(client postgres.db-two pw2 5432 require)\" = two ]"
check "a wrong password is refused" "says 'password authentication failed' postgres.db-one wrong 5432 require"
check "the other tenant's password does not open this one" "! [ \"\$(client postgres.db-one pw2 5432 require)\" = one ]"
check "an unknown tenant is refused (ENOTFOUND)" "says 'ENOTFOUND' postgres.nobody pw1 5432 require"
check "the transaction port (6543) works too" "[ \"\$(client postgres.db-one pw1 6543 require)\" = one ]"
echo "== choosing the tenant by the host name (SNI)"
# A tenant whose sni_hostname is set when it is created is found by the host name alone: the user name needs no suffix.
check "a tenant created with sni_hostname is selected by the host name (user: plain postgres)" "s=\$(tenant db-sni1 ${run}-db1 pw1 '[\"0.0.0.0/0\"]' false db-sni1.koedodb.test); { [ \$s = 201 ] || [ \$s = 200 ]; } && [ \"\$(client postgres pw1 5432 verify-full db-sni1.koedodb.test)\" = one ]"
# The real use: the tenant's manager is the database's superuser, and the clients are other roles that log in with their own passwords (the auth_query reads their hashes as the
# manager). Nothing above used such a role.
docker exec "${run}-db1" psql -U postgres -d app -qc "create role appuser login password 'apppw'; grant select on who to appuser; create role nologin_user nologin password 'x'" >/dev/null
ask() {  # user password host sql -> the answer
  docker run --rm --network "$net" -v "$work:/certs:ro" -e PGPASSWORD="$2" "$PG" psql "host=$3 port=5432 sslmode=verify-full sslrootcert=/certs/cert.pem user=$1 dbname=app connect_timeout=8" -Atc "$4" 2>&1 | head -2
}
# asks <regex> <ask args>: the answer matches. The answer is kept first (pipefail and an early grep -q would fail the pipeline).
asks() { local pat="$1"; shift; local out; out="$(ask "$@")"; grep -qiE "$pat" <<<"$out"; }
check "a role that is not a superuser logs in with its own password (the auth_query), by the host name" "[ \"\$(ask appuser apppw db-sni1.koedodb.test 'select current_user, (select rolsuper from pg_roles where rolname = current_user)')\" = 'appuser|f' ]"
check "it is that role in the database, not the manager (it cannot read what only a superuser can)" "asks 'permission denied' appuser apppw db-sni1.koedodb.test 'select rolpassword from pg_authid'"
check "its wrong password is refused" "asks 'password authentication failed' appuser nope db-sni1.koedodb.test 'select 1'"
check "a role that does not exist is refused" "asks 'password authentication failed|not found' nobody-here x db-sni1.koedodb.test 'select 1'"
check "a role that cannot log in is refused" "asks 'password authentication failed|not permitted|not found' nologin_user x db-sni1.koedodb.test 'select 1'"
check "a plain user name with a host name that no tenant has is refused (ENOIDENTIFIER)" "says 'ENOIDENTIFIER' postgres pw1 5432 require ${run}-sv"
# A failed lookup is cached by Supavisor for 24 hours, keyed by (user, tenant, host name). A client that connects before the tenant has its sni_hostname
# leaves the failure in the cache, and setting sni_hostname afterwards does not clear that entry. So set sni_hostname when the tenant is created.
tenant db-late ${run}-db1 pw1 '["0.0.0.0/0"]' false >/dev/null
first="$(client postgres pw1 5432 require db-late.koedodb.test)"
tenant db-late ${run}-db1 pw1 '["0.0.0.0/0"]' false db-late.koedodb.test >/dev/null
second="$(client postgres pw1 5432 require db-late.koedodb.test)"
if grep -q ENOIDENTIFIER <<<"$first" && grep -q ENOIDENTIFIER <<<"$second"; then
  echo "ok:   (known) a failed lookup is cached: sni_hostname added after a client already tried is not seen"
  note "so the Regional Agent must create a tenant with its sni_hostname from the start, and must never add it later"
elif [ "$second" = one ]; then
  note "sni_hostname added later IS seen in this version: the cache pitfall is gone; this note and doc/README.md can drop it"
else
  echo "FAIL: unexpected answers when sni_hostname is added later: [$first] [$second]"; fail=1
fi

echo "== the client chooses the database name"
docker exec "${run}-db1" psql -U postgres -qc "create database other" >/dev/null
docker exec "${run}-db1" psql -U postgres -d other -qc "create table who(name text); insert into who values ('other')" >/dev/null
check "a client can name another database in the same server (the tenant's db_database does not limit it)" "[ \"\$(client postgres.db-one pw1 5432 require ${run}-sv other)\" = other ]"
note "so the PostgreSQL role KoedoDB gives a customer must not be able to CONNECT to any database but the customer's own (REVOKE CONNECT ... FROM PUBLIC)"

echo "== allow_list"
subnet="$(docker network inspect "$net" --format '{{(index .IPAM.Config 0).Subnet}}')"
tenant db-three ${run}-db1 pw1 '["10.255.255.0/24"]' false >/dev/null
check "a client outside the allowed networks is refused (EADDRNOTALLOWED)" "says 'EADDRNOTALLOWED' postgres.db-three pw1 5432 require"
tenant db-three ${run}-db1 pw1 "[\"$subnet\"]" false >/dev/null
check "after the allowed network is changed to the client's, it is accepted (the change takes effect without a restart)" "[ \"\$(client postgres.db-three pw1 5432 require)\" = one ]"
tenant db-three ${run}-db1 pw1 '["10.255.255.0/24","2001:db8::/32"]' false >/dev/null
check "a list with an IPv4 and an IPv6 network is accepted by the API" "[ \"\$(api GET /api/tenants/db-three)\" = 200 ]"

echo "== TLS"
tenant db-ssl ${run}-db1 pw1 '["0.0.0.0/0"]' true >/dev/null
check "enforce_ssl: a client without TLS is refused (ESSLREQUIRED)" "says 'ESSLREQUIRED' postgres.db-ssl pw1 5432 disable"
check "enforce_ssl: a client with TLS is accepted" "[ \"\$(client postgres.db-ssl pw1 5432 require)\" = one ]"
check "the certificate is checked by a client (verify-full against the wildcard name)" "[ \"\$(client postgres.db-one pw1 5432 verify-full db-sni1.koedodb.test)\" = one ]"
check "a client without TLS is accepted when the tenant does not enforce it" "[ \"\$(client postgres.db-one pw1 5432 disable)\" = one ]"

echo "== session mode keeps the connection's state; the session port gives one server connection per client"
check "SET lasts for the whole connection on the session port" "[ \"\$(docker run --rm --network $net -e PGPASSWORD=pw1 $PG psql 'host=${run}-sv port=5432 sslmode=require user=postgres.db-one dbname=app' -Atc \"set application_name='kb'; show application_name\" | tail -1)\" = kb ]"

echo "== deleting a tenant, and restarting the server"
check "a deleted tenant can no longer connect" "s=\$(api DELETE /api/tenants/db-two); { [ \$s = 204 ] || [ \$s = 200 ]; } && says 'ENOTFOUND' postgres.db-two pw2 5432 require"
docker logs "${run}-sv" > "$work/sv-before-restart.log" 2>&1
docker rm -f "${run}-sv" >/dev/null 2>&1
check "the server starts again with the same metadata database" "start_sv"
check "the tenants survived the restart (they are in the metadata database)" "[ \"\$(client postgres.db-one pw1 5432 require)\" = one ]"
check "SNI selection survives the restart too" "[ \"\$(client postgres pw1 5432 verify-full db-sni1.koedodb.test)\" = one ]"
check "and the deleted one stays deleted" "says 'ENOTFOUND' postgres.db-two pw2 5432 require"
check "the database password is not stored in the clear in the metadata database" "! docker exec ${run}-meta psql -U postgres -Atc 'select db_password from _supavisor.users' | grep -qx pw1"

[ "$fail" = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
