#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIG
###############################################################################

PROD="${PROD:-gitlab}"
TEST="${TEST:-gitlab-test}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
MAX_WAIT="${MAX_WAIT:-600}"
ROOT_PASSWORD="${ROOT_PASSWORD:-Test123!}"

###############################################################################
# LOGGING
###############################################################################

fail()  { echo "$1" >&2; exit 1; }
info()  { echo -e "\n=== $1 ==="; }
ok()    { echo "$1"; }
waitmsg(){ echo "… $1"; }

###############################################################################
# WAIT HELPERS
###############################################################################

CHECK() {
  docker exec "$TEST" gitlab-ctl status "$1" >/dev/null 2>&1
}

WAIT_FOR_SERVICES() {
  local SERVICES=(redis gitaly puma sidekiq)
  local WAIT=0

  info "Waiting for required services: ${SERVICES[*]}"

  while (( WAIT < MAX_WAIT )); do
    local ALL_UP=true
    for svc in "${SERVICES[@]}"; do
      if ! CHECK "$svc"; then
        ALL_UP=false
        waitmsg "$svc not ready ($WAIT sec)"
        break
      fi
    done

    if $ALL_UP; then
      ok "All required services running"
      return 0
    fi

    sleep 5
    WAIT=$((WAIT+5))
  done

  fail "Required services did not start"
}

###############################################################################
# READINESS HELPER
###############################################################################

WAIT_FOR_CONTAINER_READY() {
  local NAME="$1"
  local WAIT=0

  info "Waiting for $NAME to become ready"

  docker inspect "$NAME" >/dev/null 2>&1 \
    || fail "Container '$NAME' does not exist"

  docker inspect -f '{{.State.Running}}' "$NAME" | grep -q true \
    || fail "Container '$NAME' exists but is not running"

  while (( WAIT < MAX_WAIT )); do
    if docker exec "$NAME" curl -kfsS https://localhost/-/readiness >/dev/null 2>&1; then
      ok "$NAME is READY"
      return 0
    fi
    waitmsg "$NAME not ready ($WAIT sec)"
    sleep 5
    WAIT=$((WAIT+5))
  done

  fail "$NAME did not become ready"
}

###############################################################################
# ENSURE TEST STACK IS RUNNING
###############################################################################

if ! docker inspect "$TEST" >/dev/null 2>&1; then
  info "Test container not found — bringing up TEST stack"
  docker compose -f files/test-restore.yml up -d
else
  info "Test container already exists — reuse existing TEST stack"
fi

###############################################################################
# PROD READINESS + METRICS
###############################################################################

WAIT_FOR_CONTAINER_READY "$PROD"

info "[1/10] Capturing PROD data metrics"

PROD_PROJECTS=$(docker exec "$PROD" bash -lc \
  "gitlab-rails runner \"puts Project.count\" 2>/dev/null")

PROD_WITH_REPOS=$(docker exec "$PROD" bash -lc \
  "gitlab-rails runner \"puts Project.where.not(repository_storage: nil).count\" 2>/dev/null")

info "PROD projects: $PROD_PROJECTS"
info "PROD projects w/ repos: $PROD_WITH_REPOS"

[[ "$PROD_PROJECTS" -gt 0 ]] \
  || fail "PROD project count is zero — aborting"

###############################################################################
# CREATE FULL BACKUP ON PROD
###############################################################################

info "[2/10] Creating FULL backup on $PROD"

docker exec "$PROD" gitlab-backup create

LATEST=$(docker exec "$PROD" bash -c \
  "ls -1 /var/opt/gitlab/backups/*.tar | sort | tail -n1 | xargs basename" \
  | tr -d '\r\n ')

[[ -z "$LATEST" ]] && fail "Could not detect backup filename"

STAMP="${LATEST%_gitlab_backup.tar}"

mkdir -p "$BACKUP_DIR"
docker cp "$PROD:/var/opt/gitlab/backups/$LATEST" "$BACKUP_DIR/$LATEST"

info "Using backup: $LATEST"

###############################################################################
# PREPARE TEST INSTANCE
###############################################################################

#WAIT_FOR_CONTAINER_READY "$TEST"

info "[3/10] Preparing $TEST for restore"

docker exec "$TEST" gitlab-ctl stop puma || true
docker exec "$TEST" gitlab-ctl stop sidekiq || true

docker exec "$TEST" gitlab-ctl start redis || true
docker exec "$TEST" gitlab-ctl start gitaly || true

sleep 5

###############################################################################
# COPY BACKUP TO TEST
###############################################################################

info "[4/10] Preparing backup on $TEST"

docker exec "$TEST" mkdir -p /var/opt/gitlab/backups
docker cp "$BACKUP_DIR/$LATEST" "$TEST:/var/opt/gitlab/backups/$LATEST"

docker exec "$TEST" chown git:git "/var/opt/gitlab/backups/$LATEST"
docker exec "$TEST" chmod 600 "/var/opt/gitlab/backups/$LATEST"

###############################################################################
# RESTORE BACKUP
###############################################################################

info "[5/10] Running GitLab restore"

docker exec -i "$TEST" sh -c \
  "yes yes | gitlab-backup restore BACKUP='$STAMP'"

###############################################################################
# RECONFIGURE
###############################################################################

info "[6/10] Reconfiguring GitLab after restore"

docker exec "$TEST" gitlab-ctl reconfigure

###############################################################################
# RESTART
###############################################################################

info "[7/10] Restarting GitLab"

docker exec "$TEST" gitlab-ctl restart
WAIT_FOR_SERVICES

###############################################################################
# RESET ROOT PASSWORD
###############################################################################

info "[8/10] Setting root password"

docker exec "$TEST" bash -c \
"NEW_ROOT_PASSWORD=\"$ROOT_PASSWORD\" gitlab-rails runner - <<'RUBY' 2>/dev/null
u = User.find_by_username('root')
if u
  u.password = ENV['NEW_ROOT_PASSWORD']
  u.password_confirmation = ENV['NEW_ROOT_PASSWORD']
  u.save!
end
RUBY"

###############################################################################
# CANCEL RESTORED PIPELINES
###############################################################################

info "[9/10] Cleaning up restored pipelines"

docker exec "$TEST" gitlab-rails runner - <<'RUBY' 2>/dev/null
begin
  %w[running pending].each do |state|
    Ci::Pipeline.where(status: state).each(&:cancel)
  end
rescue => e
  puts "Warning: pipeline cleanup skipped (#{e.class})"
end
RUBY

###############################################################################
# READINESS + DATA INTEGRITY VALIDATION
###############################################################################

WAIT_FOR_CONTAINER_READY "$TEST"

info "[10/10] Validating restored data integrity"

TEST_PROJECTS=$(docker exec "$TEST" bash -lc \
  "gitlab-rails runner \"puts Project.count\" 2>/dev/null")

TEST_WITH_REPOS=$(docker exec "$TEST" bash -lc \
  "gitlab-rails runner \"puts Project.where.not(repository_storage: nil).count\" 2>/dev/null")

info "TEST projects: $TEST_PROJECTS"
info "TEST projects w/ repos: $TEST_WITH_REPOS"

[[ "$TEST_PROJECTS" -eq "$PROD_PROJECTS" ]] \
  || fail "Project count mismatch (PROD=$PROD_PROJECTS TEST=$TEST_PROJECTS)"

[[ "$TEST_WITH_REPOS" -eq "$PROD_WITH_REPOS" ]] \
  || fail "Repo count mismatch (PROD=$PROD_WITH_REPOS TEST=$TEST_WITH_REPOS)"

ok "Data integrity validated"
ok "RESTORE SUCCESS — GitLab-test is verified and healthy"

info "[CLEANUP] Pruning backups"
docker exec "$PROD" bash -c "ls -1t /var/opt/gitlab/backups/*.tar | tail -n +2 | xargs -r rm -f"

info "[CLEANUP] Teardown gitlab-test"
docker compose -f files/test-restore.yml down -v

ok "[COMPLETE]"

