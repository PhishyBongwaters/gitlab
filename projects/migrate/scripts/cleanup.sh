#!/bin/bash
set -euo pipefail

###############################################################################
# LOGGING
###############################################################################

info()  { echo -e "\n=== $1 ==="; }
ok()    { echo "$1"; }

info "[CLEANUP] Take down gitlab-test"
docker compose -f files/migrate-compose.yml down -v
docker volume prune -f
ok "[COMPLETE]"
