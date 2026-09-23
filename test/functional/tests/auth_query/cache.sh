#!/bin/bash

set -euo pipefail

cache_tmp=$(mktemp -d)
cleanup() {
	rc=$?
	if [ "$rc" -ne 0 ]; then
		cat "$cache_tmp"/* /var/log/odyssey.log
	fi
	sql 'DELETE FROM auth_query_cache_test.gate' > /dev/null 2>&1 || true
	rm -rf "$cache_tmp"
	exit "$rc"
}
trap cleanup EXIT

sql() {
	psql -X -At -v ON_ERROR_STOP=1 -h localhost -p 5432 -U postgres \
		-d postgres -c "$1"
}

connect() {
	PGPASSWORD="$2" PGCONNECT_TIMEOUT=5 psql -X -At -v ON_ERROR_STOP=1 \
		-h "${3:-127.0.0.1}" -p 6432 -U "$1" \
		-d "${4:-auth_query_cache_db}" -c 'SELECT pg_backend_pid()'
}

reject() {
	if connect "$1" "$2" "${4:-127.0.0.1}" "${5:-auth_query_cache_db}" \
		> "$cache_tmp/rejected" 2>&1; then
		echo "ERROR: accepted rejected credentials for $1"
		exit 1
	fi
	grep -q "$3" "$cache_tmp/rejected"
}

alice_backend=$(connect cache_alice alpha)
bob_backend=$(connect cache_bob beta)
test "$alice_backend" = "$bob_backend"
reject cache_alice beta 'password authentication failed'
reject cache_bob alpha 'password authentication failed'
connect cache_alice alpha > /dev/null
connect cache_bob beta > /dev/null
test "$(sql 'SELECT count(*) FROM auth_query_cache_test.requests')" = 2

pids=()
for n in $(seq 1 8); do
	connect cache_parallel parallel > "$cache_tmp/parallel_$n" 2>&1 &
	pids+=("$!")
done
parallel_failed=0
for pid in "${pids[@]}"; do
	wait "$pid" || parallel_failed=1
done
test "$parallel_failed" = 0
test "$(sql "SELECT count(*) FROM auth_query_cache_test.requests WHERE username = 'cache_parallel'")" = 1

reload_backend=$(connect cache_reload before 127.0.0.1 auth_query_reload_db)

sql "INSERT INTO auth_query_cache_test.failures VALUES ('cache_retry')"
reject cache_retry epsilon 'failed to make auth query'
sql "DELETE FROM auth_query_cache_test.failures WHERE username = 'cache_retry'"
connect cache_retry epsilon > /dev/null

connect cache_error delta > /dev/null
sql "DELETE FROM auth_query_cache_test.credentials WHERE username = 'cache_alice';
     UPDATE auth_query_cache_test.credentials SET password = NULL WHERE username = 'cache_bob';
     INSERT INTO auth_query_cache_test.failures VALUES ('cache_error')"

deadline=$((SECONDS + 25))
alice_denied=0
bob_denied=0
while [ "$SECONDS" -lt "$deadline" ]; do
	if ! connect cache_alice alpha > "$cache_tmp/alice" 2>&1; then
		grep -q 'incorrect user' "$cache_tmp/alice"
		alice_denied=1
	fi
	if ! connect cache_bob beta > "$cache_tmp/bob" 2>&1; then
		grep -q 'incorrect user' "$cache_tmp/bob"
		bob_denied=1
	fi
	connect cache_error delta > /dev/null
	if [ "$alice_denied" = 1 ] && [ "$bob_denied" = 1 ] &&
		grep -q 'auth query cache test failure for cache_error' /var/log/odyssey.log; then
		break
	fi
	sleep 0.1
done
test "$alice_denied" = 1
test "$bob_denied" = 1
grep -q 'auth query cache test failure for cache_error' /var/log/odyssey.log
reject cache_alice alpha 'incorrect user'
reject cache_bob beta 'incorrect user'
connect cache_error delta > /dev/null
reject cache_error wrong 'password authentication failed'

sql "INSERT INTO auth_query_cache_test.credentials
     SELECT 'cache_' || n, 'password_' || n FROM generate_series(1, 70) n"
for n in $(seq 1 70); do
	connect "cache_$n" "password_$n" > /dev/null
done
connect cache_70 password_70 > /dev/null
test "$(sql "SELECT count(*) FROM auth_query_cache_test.requests WHERE username = 'cache_70'")" = 1
test "$(sql "SELECT count(*) FROM auth_query_cache_test.requests WHERE username = 'cache_1'")" = 1
reject cache_alice alpha 'incorrect user'
reject cache_1 password_70 'password authentication failed'
connect cache_1 password_1 > /dev/null
test "$(sql "SELECT count(*) FROM auth_query_cache_test.requests WHERE username = 'cache_1'")" = 2

age_backend=$(connect cache_age before 127.0.0.1 auth_query_age_db)
sql "INSERT INTO auth_query_cache_test.failures VALUES ('cache_age')"
test "$(connect cache_age before 127.0.0.1 auth_query_age_db)" = "$age_backend"
deadline=$((SECONDS + 5))
while connect cache_age before 127.0.0.1 auth_query_age_db > "$cache_tmp/age" 2>&1; do
	test "$SECONDS" -lt "$deadline"
	sleep 0.1
done
grep -q 'failed to make auth query' "$cache_tmp/age"
reject cache_age before 'failed to make auth query' 127.0.0.1 auth_query_age_db

sql "UPDATE auth_query_cache_test.credentials SET password = 'after' WHERE username = 'cache_age';
     DELETE FROM auth_query_cache_test.failures WHERE username = 'cache_age'"
deadline=$((SECONDS + 5))
until connect cache_age after 127.0.0.1 auth_query_age_db > "$cache_tmp/age" 2>&1; do
	test "$SECONDS" -lt "$deadline"
	sleep 0.1
done
test "$(cat "$cache_tmp/age")" = "$age_backend"
reject cache_age before 'password authentication failed' 127.0.0.1 auth_query_age_db

sql 'INSERT INTO auth_query_cache_test.gate VALUES (true)'
deadline=$((SECONDS + 20))
while [ "$(sql "SELECT count(*) FROM pg_stat_activity WHERE datname = 'postgres'
                AND query = 'SELECT * FROM auth_query_cache_test.lookup(\$1)'
                AND wait_event = 'PgSleep'")" = 0 ]; do
	connect cache_reload before 127.0.0.1 auth_query_reload_db > /dev/null
	test "$SECONDS" -lt "$deadline"
	sleep 0.05
done

reloads=$(grep -c 'routes created/deleted and scheduled for removal' /var/log/odyssey.log || true)
sed -i '/database "auth_query_source" {/,/^}/ s/storage_db "postgres"/storage_db "auth_query_source_new"/' "$1"
sed -i '/auth_query_max_age 2/d' "$1"
kill -HUP "$(cat /var/run/odyssey.pid)"
deadline=$((SECONDS + 5))
while [ "$(grep -c 'routes created/deleted and scheduled for removal' /var/log/odyssey.log || true)" -le "$reloads" ]; do
	test "$SECONDS" -lt "$deadline"
	sleep 0.05
done
test "$(connect cache_reload after 127.0.0.1 auth_query_reload_db)" = "$reload_backend"
reject cache_reload before 'password authentication failed' 127.0.0.1 auth_query_reload_db

connect cache_age after 127.0.0.1 auth_query_age_db > /dev/null
sql "INSERT INTO auth_query_cache_test.failures VALUES ('cache_age')"
sleep 2.1
connect cache_age after 127.0.0.1 auth_query_age_db > /dev/null
sql "DELETE FROM auth_query_cache_test.failures WHERE username = 'cache_age'"

sql 'DELETE FROM auth_query_cache_test.gate'
deadline=$((SECONDS + 5))
while [ "$(sql "SELECT count(*) FROM auth_query_cache_test.requests WHERE username = 'cache_reload'")" -lt 2 ]; do
	test "$SECONDS" -lt "$deadline"
	sleep 0.05
done
test "$(connect cache_reload after 127.0.0.1 auth_query_reload_db)" = "$reload_backend"
reject cache_reload before 'password authentication failed' 127.0.0.1 auth_query_reload_db
