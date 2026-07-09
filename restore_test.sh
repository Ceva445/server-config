#!/bin/bash
# Test restore: restore the latest backup into a throwaway container and
# compare per-table row counts with the live production database.
# Does NOT touch production. Usage: restore_test.sh <project-folder>
set -uo pipefail

PROJECT="$1"
APPS=/home/piatek/Desktop/apps
BACKUPS=/home/piatek/Desktop/backups
CT=restore-test-db

DUMP=$(ls -t "$BACKUPS/$PROJECT"/*.sql.gz 2>/dev/null | head -1)
if [ -z "$DUMP" ]; then echo "No backup found for $PROJECT"; exit 1; fi
eval "$(grep -E '^POSTGRES_(USER|DB)=' "$APPS/$PROJECT/.env")"
DBU=$POSTGRES_USER
DBN=$POSTGRES_DB
echo "### Project: $PROJECT"
echo "### Dump:    $(basename "$DUMP")  ($(du -h "$DUMP" | cut -f1))"
echo "### Target:  user=$DBU db=$DBN"

# per-table exact row counts for a given container
counts() {
    local ct=$1
    docker exec "$ct" psql -U "$DBU" -d "$DBN" -t -A \
        -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename" \
    | while read -r t; do
        [ -z "$t" ] && continue
        c=$(docker exec "$ct" psql -U "$DBU" -d "$DBN" -t -A -c "SELECT count(*) FROM \"$t\"")
        echo "$t=$c"
    done
}

# 1. throwaway container
docker rm -f "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" \
    -e POSTGRES_USER="$DBU" -e POSTGRES_PASSWORD=x -e POSTGRES_DB="$DBN" \
    postgres:17 >/dev/null
printf "### Waiting for temp postgres"
until docker exec "$CT" pg_isready -U "$DBU" -d "$DBN" >/dev/null 2>&1; do printf .; sleep 1; done
echo " ready"

# 2. restore
echo "### Restoring..."
gunzip -c "$DUMP" | docker exec -i "$CT" psql -q -U "$DBU" -d "$DBN" \
    -v ON_ERROR_STOP=0 >/tmp/restore_$PROJECT.log 2>&1
errs=$(grep -ci error /tmp/restore_$PROJECT.log)
echo "### psql errors during restore: $errs"
[ "$errs" -gt 0 ] && grep -i error /tmp/restore_$PROJECT.log | head -5

# 3. compare with production
PROD_CT=$(cd "$APPS/$PROJECT" && docker compose ps -q db)
counts "$CT"      | sort > /tmp/restored_$PROJECT.txt
counts "$PROD_CT" | sort > /tmp/prod_$PROJECT.txt

tbl=$(wc -l < /tmp/restored_$PROJECT.txt)
rows=$(awk -F= '{s+=$2} END{print s}' /tmp/restored_$PROJECT.txt)
echo "### Restored: $tbl tables, $rows total rows"

echo "### Diff restored vs production (empty = identical):"
if diff /tmp/restored_$PROJECT.txt /tmp/prod_$PROJECT.txt; then
    echo ">>> PASS: restored database is identical to production"
    RESULT=0
else
    echo ">>> MISMATCH (see diff above)"
    RESULT=1
fi

# 4. cleanup
docker rm -f "$CT" >/dev/null
echo "### Temp container removed"
exit $RESULT
