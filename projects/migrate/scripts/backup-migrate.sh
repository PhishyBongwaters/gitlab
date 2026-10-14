#!/bin/bash
set -euo pipefail

###############################################################################
# CONFIG
###############################################################################

PROD="${PROD:-gitlab}"
TEST="${TEST:-gitlab-test}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
MAX_WAIT="${MAX_WAIT:-600}"
# Skip registry blobs in test backups: registry is what blows the backup
# to 9.2G. Set BACKUP_SKIP="" in CI for a full backup.
BACKUP_SKIP="${BACKUP_SKIP:-registry}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"  # Set via CI variable; hardcoded test password removed

###############################################################################
# LOGGING
###############################################################################

fail()  { echo "$1" >&2; exit 1; }
info()  { echo -e "\n=== $1 ==="; }
ok()    { echo "$1"; }

# Fail fast if the required test password was not provided via CI variables.
[[ -n "${ROOT_PASSWORD:-}" ]] || fail "ROOT_PASSWORD must be set (CI variable)"
waitmsg(){ echo "… $1"; }

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
if ! docker inspect "$TEST" >/dev/null 2>&1; then
  info "Test container not found — bringing up TEST stack"
  docker compose -f files/test-migrate.yml up -d
else
  info "Test container already exists — reuse existing TEST stack"
fi

# PROD READINESS + METRICS
info "[1/13] Capturing PROD data metrics"

WAIT_FOR_CONTAINER_READY "$PROD"

PROD_PROJECTS=$(docker exec "$PROD" bash -lc \
  "gitlab-rails runner \"puts Project.count\" 2>/dev/null")

PROD_WITH_REPOS=$(docker exec "$PROD" bash -lc \
  "gitlab-rails runner \"puts Project.where.not(repository_storage: nil).count\" 2>/dev/null")

info "PROD projects: $PROD_PROJECTS"
info "PROD projects w/ repos: $PROD_WITH_REPOS"

[[ "$PROD_PROJECTS" -gt 0 ]] \
  || fail "PROD project count is zero — aborting"

# CREATE FULL BACKUP ON PROD
info "[2/13] Creating FULL backup on $PROD"

docker exec "$PROD" gitlab-backup create SKIP="$BACKUP_SKIP"

LATEST=$(docker exec "$PROD" bash -c \
  "ls -1 /var/opt/gitlab/backups/*.tar | sort | tail -n1 | xargs basename" \
  | tr -d '\r\n ')

[[ -z "$LATEST" ]] && fail "Could not detect backup filename"

STAMP="${LATEST%_gitlab_backup.tar}"

mkdir -p "$BACKUP_DIR"
docker cp "$PROD:/var/opt/gitlab/backups/$LATEST" "$BACKUP_DIR/$LATEST"

info "Using backup: $LATEST"

# PREPARE TEST INSTANCE

#WAIT_FOR_CONTAINER_READY "$TEST"

info "[3/13] Preparing $TEST for restore"

docker exec "$TEST" gitlab-ctl stop puma || true
docker exec "$TEST" gitlab-ctl stop sidekiq || true

docker exec "$TEST" gitlab-ctl start redis || true
docker exec "$TEST" gitlab-ctl start gitaly || true

sleep 5

# COPY BACKUP TO TEST

info "[4/13] Preparing backup on $TEST"

docker exec "$TEST" mkdir -p /var/opt/gitlab/backups
docker cp "$BACKUP_DIR/$LATEST" "$TEST:/var/opt/gitlab/backups/$LATEST"

docker exec "$TEST" chown git:git "/var/opt/gitlab/backups/$LATEST"
docker exec "$TEST" chmod 600 "/var/opt/gitlab/backups/$LATEST"

# Delete intermediate host copy: PROD -> ./backups -> TEST held 3 copies
# of the same backup on the same disk. Keep only PROD + TEST during restore.
rm -f "$BACKUP_DIR/$LATEST"

# RESTORE BACKUP

info "[5/13] Running GitLab restore"

docker exec -i "$TEST" sh -c \
  "yes yes | gitlab-backup restore BACKUP='$STAMP' SKIP='$BACKUP_SKIP'"

# Delete TEST backup copy after restore: no longer needed, frees volume
# space before reconfigure/restart.
docker exec "$TEST" rm -f "/var/opt/gitlab/backups/$LATEST"

# RECONFIGURE

info "[6/13] Reconfiguring GitLab after restore"

docker exec "$TEST" gitlab-ctl reconfigure

# RESTART

info "[7/13] Restarting GitLab"

docker exec "$TEST" gitlab-ctl restart
WAIT_FOR_SERVICES

# RESET ROOT PASSWORD

info "[8/13] Setting root password"

# Use gitlab-rails runner (not bash -c with Ruby) and pass the password
# via docker exec -e so it never appears in the command line.
docker exec -e NEW_ROOT_PASSWORD="$ROOT_PASSWORD" "$TEST" gitlab-rails runner "u = User.find_by_username('root'); if u; u.password = ENV['NEW_ROOT_PASSWORD']; u.password_confirmation = ENV['NEW_ROOT_PASSWORD']; u.save!; end"

# CANCEL RESTORED PIPELINES

info "[9/13] Cleaning up restored pipelines"

docker exec "$TEST" gitlab-rails runner - <<'RUBY' 2>/dev/null
begin
  %w[running pending].each do |state|
    Ci::Pipeline.where(status: state).each(&:cancel)
  end
rescue => e
  puts "Warning: pipeline cleanup skipped (#{e.class})"
end
RUBY

# DATA INTEGRITY VALIDATION

WAIT_FOR_CONTAINER_READY "$TEST"

info "[10/13] Validating restored data integrity"

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

info "[11/13] Pruning backups"
docker exec "$PROD" bash -c "ls -1t /var/opt/gitlab/backups/*.tar | tail -n +2 | xargs -r rm -f"

# MIGRATION VALIDATION
info "[11/13] Validating database migrations (19.4.1)"

FAILED_MIGRATIONS=$(
  docker exec "$TEST" bash -lc "gitlab-rake db:migrate:status" \
    | awk '$1 == "down" { count++ } END { print count+0 }'
)

if (( FAILED_MIGRATIONS > 0 )); then
  fail "Upgrade validation FAILED: $FAILED_MIGRATIONS pending migrations"
fi

ok "Upgrade validation OK: no pending migrations"


# Swap container images via compose files
info "[12/13] Take down gitlab-test (before upgrade)"
docker compose -f files/test-migrate.yml down 

info "[12/13] Bring up gitlab-test (latest)"
docker compose -f files/migrate-compose.yml up -d

# The new image's entrypoint reconfigure dies on IrreversibleOrderError
# (keyset pagination / ApplicationSetting) during cache:clear before
# migrations run, so the container never becomes ready. Run migrations
# explicitly first (retry while Postgres comes up), then reconfigure,
# then wait for readiness.
info "[12/13] Running DB migrations before readiness check"
docker exec "$TEST" gitlab-ctl start postgresql || true
docker exec "$TEST" gitlab-ctl start redis || true
for i in $(seq 1 12); do
  if docker exec "$TEST" bash -lc "gitlab-rake db:migrate"; then
    break
  fi
  waitmsg "db:migrate not ready (attempt $i/12), retrying in 10s"
  sleep 10
  if [ "$i" -eq 12 ]; then
    fail "db:migrate failed after 12 attempts"
  fi
done
docker exec "$TEST" gitlab-ctl reconfigure

WAIT_FOR_CONTAINER_READY "$TEST"

# UPGRADE MIGRATION VALIDATION
info "[13/13] Validating database migrations"

FAILED_MIGRATIONS=$(
  docker exec "$TEST" bash -lc "gitlab-rake db:migrate:status" \
    | awk '$1 == "down" { count++ } END { print count+0 }'
)

if (( FAILED_MIGRATIONS > 0 )); then
  fail "Upgrade validation FAILED: $FAILED_MIGRATIONS pending migrations"
fi

ok "[13/13] Migrations complete"

info "[13/13] Take down gitlab-test"
docker compose -f files/migrate-compose.yml down -v
docker volume prune -f

info "Upgrade is complete but background tasks will take a few minutes"

ok "[COMPLETE]"
