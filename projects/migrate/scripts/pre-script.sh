#!/bin/bash
set -euo pipefail

###############################################################################
# LOGGING
###############################################################################

info()  { echo -e "\n=== $1 ==="; }
ok()    { echo "$1"; }

info "[Setup] Getting latest gitlab image"
docker pull gitlab/gitlab-ce:latest
ok "[COMPLETE]"
