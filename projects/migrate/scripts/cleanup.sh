#!/bin/bash
set -euo pipefail

###############################################################################
# LOGGING
###############################################################################

info()  { echo -e "\n=== $1 ==="; }
ok()    { echo "$1"; }

# Capture diagnostics BEFORE teardown, so a failure still leaves logs.
# Best-effort only: none of these may abort cleanup.
info "[CLEANUP] Capturing diagnostics before teardown"
docker logs gitlab-test > gitlab-test.log 2>&1 || true
df -h > disk-before-cleanup.log 2>&1 || true
docker system df > docker-system-df.log 2>&1 || true
docker compose -f files/test-migrate.yml logs > test-migrate.log 2>&1 || true

info "[CLEANUP] Take down gitlab-test"
# Down BOTH compose files: a failure before the swap leaves TEST on
# test-migrate.yml, a failure after leaves it on migrate-compose.yml.
# Each down must not abort the other (previous version used bare
# `down -v` under `set -e`, so a first failure skipped the second).
docker compose -f files/test-migrate.yml down -v || true
docker compose -f files/migrate-compose.yml down -v || true

# Remove the intermediate host copy of the backup (./backups/*.tar).
# backup-migrate.sh copies PROD -> ./backups -> TEST, so on failure this
# copy would otherwise linger and eat disk on the next run.
rm -rf ./backups || true

docker volume prune -f || true
# Dangling-only image prune: frees layers from pulled `latest` images
# without deleting the in-use gitlab images. Do NOT use `prune -a` here.
docker image prune -f || true
ok "[COMPLETE]"
