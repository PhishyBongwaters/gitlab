#!/bin/bash
set -euo pipefail

###############################################################################
# LOGGING
###############################################################################

info()  { echo -e "\n=== $1 ==="; }
ok()    { echo "$1"; }
fail()  { echo "$1" >&2; exit 1; }

# Disk preflight: fail fast with a clear message instead of ENOSPC
# mid-backup (job #162 died in `gitlab-backup create` at
# `fptr_finalize_flush` because `/` filled during the backup).
# The migration holds up to ~3 copies of the backup at once on the same
# disk (PROD + ./backups + TEST), so require headroom up front.
MIN_FREE_GB="${MIN_FREE_GB:-20}"
info "[Preflight] Checking free disk (need >= ${MIN_FREE_GB}G)"
df -h || true
docker system df || true
FREE_GB=$(df --output=avail -BG . | tail -n1 | tr -d ' G')
if [ "${FREE_GB}" -lt "${MIN_FREE_GB}" ]; then
  fail "Not enough free disk: ${FREE_GB}G available, need >= ${MIN_FREE_GB}G (set MIN_FREE_GB to override). Free space or prune Docker resources before retry."
fi
ok "Free disk OK: ${FREE_GB}G available"

# Fresh TEST stack: tear down any leftover TEST from a previous failed
# run before backup-migrate.sh checks `docker inspect gitlab-test`.
# Reusing a dirty TEST volume wastes disk and can contaminate the next
# restore validation with the previous run's data.
info "[Setup] Clearing leftover TEST stack from previous runs"
docker compose -f files/test-migrate.yml down -v || true
docker compose -f files/migrate-compose.yml down -v || true
docker volume prune -f || true
# Dangling-only image prune: frees layers from previous `latest` pulls
# without deleting in-use images. Do NOT use `prune -a` here.
docker image prune -f || true

# Pre-backup prune: keep only the newest PROD backup BEFORE creating a
# new one, so the new backup has room. The old prune in backup-migrate.sh
# only ran on the success path, after validation, so a failure at
# `backup:create` never freed anything.
if docker inspect gitlab >/dev/null 2>&1; then
  info "[Setup] Pruning old PROD backups (keep newest 1)"
  docker exec gitlab bash -c "ls -1t /var/opt/gitlab/backups/*.tar 2>/dev/null | tail -n +2 | xargs -r rm -f" || true
fi

info "[Setup] Getting latest gitlab image"
docker pull gitlab/gitlab-ce:latest
ok "[COMPLETE]"
