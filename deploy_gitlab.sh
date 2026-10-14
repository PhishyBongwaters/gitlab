#!/usr/bin/env bash
: <<'COMMENT'
##########################################################################
  Title: Complete & Accurate Synopsis — Automated GitLab CE + Test Instance +
         Mirror/Maint Deployment, Runners, TLS, Registry, and CI Validation

  ## Purpose
  Completely automates provisioning of a *full GitLab CE environment* using
  Docker Compose, including:

  - TLS certificate generation (mkcert or OpenSSL)
  - GitLab CE (production) + Postgres provisioning
  - Test GitLab bind‑mount preparation for restore validation workflows
  - DevOps group bootstrap
  - Mirror project deployment, CI verification, and registry validation
  - Maint project deployment for backup/restore workflows
  - Docker executor group runner (DevOps runner)
  - Host-admin shell runner (root, system‑mode)
  - SSH key setup for the root GitLab account
  - CA trust injection into host + Docker daemon
  - Fully automated push → pipeline → validation sequence

  Result:
  A single script that deploys an entire working GitLab ecosystem capable of:
  - Image mirroring
  - Automated repo pushes
  - CI pipeline execution + success verification
  - Backup → restore → validation (maint project)
  - Host-level execution via shell runner
  - Registry authentication and test image pull

  ---
  
  ## Invocation & Options
  Run with root privileges:

      sudo bash ./<script>.sh

  Optional flags:
    - `-hosts`       → Add GITLAB_HOST → GITLAB_HOST_IP entry to /etc/hosts  
    - `-client-tls`  → Install GitLab TLS CA to host trust store + restart Docker

  Root is required for accurate bind-mount ownership, TLS installation, and
  systemd runner management.

  ---

  ## Inputs & Configuration

  ### `.env` support
  The script automatically loads `.env` from the script directory (even under
  sudo), supporting variables including:

    - GITLAB_HOST               (default: gitlab.local)
    - GITLAB_HTTP_PORT          (default: 80)
    - GITLAB_HTTPS_PORT         (default: 443)
    - GITLAB_SSH_PORT           (default: 2222)
    - GITLAB_REGISTRY_PORT      (optional, for registry auth summary)
    - DEVOPS_GROUP_NAME         (default: DevOps)
    - DEVOPS_GROUP_PATH         (default: devops)
    - MIRROR_PROJECT_NAME       (default: mirror)
    - MAINT_PROJECT_NAME        (default: maint)
    - DEVOPS_RUNNER_DESCRIPTION (docker runner)
    - DEVOPS_RUNNER_TAGS        (docker runner tags)
    - SSH_KEY_COMMENT           (default: gitlab-local)
    - CERTS_DIR                 (default: certs/)
    - GITLAB_HOST_IP            (optional, used by -hosts)

  ### Derived variables
  Computed internally:

    - GITLAB_URL = https://${GITLAB_HOST}:${GITLAB_HTTPS_PORT}
    - MIRROR_LOCAL_DIR = ./mirror/
    - MAINT_LOCAL_DIR  = ./maint/
    - SSH public key expected at ${USER_HOME}/.ssh/id_ed25519.pub

  ---

  ## Prerequisites (validated at runtime)
    - docker
    - docker compose (v2)
    - jq
    - curl

  Missing dependencies produce an immediate hard failure.

  ---

  ## High-Level Flow (Production + Test + Mirror + Maint)

  1. **Dependency Check**
     Ensures docker, docker compose, jq, and curl exist.

  2. **Optional /etc/hosts Update**
     Adds "GITLAB_HOST_IP GITLAB_HOST" if -hosts supplied.

  3. **TLS Preparation**
     - Generates or reuses cert.pem + key.pem
     - Supports mkcert or OpenSSL fallback
     - Produces SANs for GitLab + registry

  4. **Bind-Mount Directory Preparation**
     **Production**:
       - gitlab-data/{config,logs,data} created
       - redis/alertmanager/prometheus numeric UID ownership applied
     **Test Instance**:
       - postgres-test-data, gitlab-test-data prepared for restore validation

  5. **Start Docker Compose Services**
     Brings GitLab, Postgres, GitLab Runner (docker executor) online.

  6. **GitLab Readiness Probe**
     Waits for /-/ready for up to 900 seconds.

  7. **GitLab Bootstrap**
     - Reads root password from container
     - Creates a root PAT with api + create_runner
     - Disables signups, sets global default branch, enforces repo size limit
     - Ensures ed25519 SSH key exists and is added to root GitLab account

  8. **DevOps Group + Project Creation**
     - Creates (or finds) the DevOps group
     - Creates (or finds) the mirror and maint projects
     - Ensures default_branch=main

  9. **Docker Executor DevOps Runner**
     - Registers via new GitLab runner-auth flow
     - Tags + restricts untagged jobs
     - Attaches runner to mirror project
     - Installs CA bundle in runner container for HTTPS cloning

  10. **Known Hosts Cleanup**
      Removes stale `port` SSH entries for safe git push.

  11. **Push Mirror Repository**
      - Builds mirror repo from local files
      - Pushes via SSH
      - Triggers CI automatically

  12. **Mirror Pipeline Monitoring**
      Actively checks until pipeline reports success/failure/timeout.

  13. **Maint Repository Creation + Push**
      - Creates or finds maint project
      - Pushes initial commit
      - Verifies a pipeline *record* exists (manual job = no auto-run)
      - Used for backup/restore validation patterns

  14. **Client TLS + Registry Authentication (Optional)**
      - Installs GitLab CA to host trust store
      - Restarts Docker to apply trust
      - Logs in to GitLab container registry
      - Performs successful test image pull

  15. **Host-Admin Shell Runner**
      - Installs host-level GitLab Runner (system-mode)
      - Registers group-scoped shell executor runner
      - Applies tags + locking via API
      - Ensures config is loaded via service restart
      - Enables host-level maintenance / restore automation

  16. **Final Summary**
      Prints URLs, tokens, runner tags, SSH commands, and registry login hints.

  ---

  ## Error Handling Highlights
  - Hard fail on:
      - Missing dependencies
      - GitLab readiness timeout
      - PAT creation failure
      - Missing mirror/maint local files
      - Push failures
      - Mirror pipeline failure or timeout
      - Invalid group or project IDs
      - Unsuccessful runner registration
      - Missing or invalid privileged context where required

##########################################################################
COMMENT

set -Eeuo pipefail
IFS=$'\n\t'

USE_HOSTS=false
SETUP_CLIENT_TLS=false

for arg in "$@"; do
  case "$arg" in
    -hosts) USE_HOSTS=true ;;
    -client-tls) SETUP_CLIENT_TLS=true ;;
  esac
done

# Require root
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run this script with sudo/root." >&2
  exit 1
fi

# Load .env from script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${GITLAB_HOST:=gitlab.local}"
: "${GITLAB_HTTP_PORT:=80}"
: "${GITLAB_HTTPS_PORT:=443}"
: "${GITLAB_SSH_PORT:=2222}"
: "${DEVOPS_GROUP_NAME:=DevOps}"
: "${DEVOPS_GROUP_PATH:=devops}"
: "${MIRROR_PROJECT_NAME:=mirror}"
: "${DEVOPS_RUNNER_DESCRIPTION:=docker-runner-devops}"
: "${DEVOPS_RUNNER_TAGS:=devops}"
: "${SSH_KEY_COMMENT:=gitlab-local}"
: "${MIRROR_LOCAL_DIR:=projects/mirror}"
: "${MAINT_LOCAL_DIR:=projects/maint}"
: "${MAINT_PROJECT_NAME:=maint}"
: "${MIRROR_PROJECT_NAME:=mirror}"

# Derived
GITLAB_URL="https://${GITLAB_HOST}:${GITLAB_HTTPS_PORT}"
#MIRROR_LOCAL_DIR="mirror"  # expects ./mirror/images.txt and ./mirror/.gitlab-ci.yml
MIRROR_SSH_URL="ssh://git@${GITLAB_HOST}:${GITLAB_SSH_PORT}/${DEVOPS_GROUP_PATH}/${MIRROR_PROJECT_NAME}.git"

#MAINT_LOCAL_DIR="maint"
MAINT_SSH_URL="ssh://git@${GITLAB_HOST}:${GITLAB_SSH_PORT}/${DEVOPS_GROUP_PATH}/${MAINT_PROJECT_NAME}.git"
MAINT_PROJECT_ID=""

# Determine user's home dir even when run with sudo
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  USER_HOME="$HOME"
fi
SSH_KEY_PATH="$USER_HOME/.ssh/id_ed25519.pub"

# IDs discovered at runtime
DEVOPS_GROUP_ID="2"
MIRROR_PROJECT_ID=""

PAT="glpat-fikj4cQbktn6NeKQLDk5sW86MQp1OjEH.01.0w05v9tel"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

INITIAL_PASSWORD=""
PAT=""

main() {  
  #check_deps
  #setup_hosts
  #prepare_gitlab_tls
  #prepare_data_dirs
  #start_docker
  #wait_for_gitlab
  #configure_gitlab
  #wait_for_gitlab_api_json
  #create_group_devops
  #create_project_mirror_in_group
  #register_runner_devops_group_authflow
  #cleanup_known_hosts
  #push_mirror_repo
  #verify_pipeline_for "${DEVOPS_GROUP_PATH}%2F${MIRROR_PROJECT_NAME}" 
  #create_and_push_maint_repo
  #setup_client_tls_and_auth
  install_host_admin_runner_if_missing
  #summary
}

check_deps() {
  log_info "Checking for dependencies..."
  command -v docker >/dev/null 2>&1 || log_error "Docker is not installed."
  docker compose version >/dev/null 2>&1 || log_error "Docker Compose is not installed."
  command -v jq >/dev/null 2>&1 || log_error "jq is not installed."
  command -v curl >/dev/null 2>&1 || log_error "curl is not installed."
  log_success "All dependencies are installed."
}

setup_hosts() {  
  if [[ "$USE_HOSTS" != "true" ]]; then
    return
  fi
  local host_ip
  host_ip="${GITLAB_HOST_IP:-127.0.0.1}"
  log_info "Ensuring ${GITLAB_HOST} maps to ${host_ip} in /etc/hosts..."
  if grep -E -q "^[[:space:]]*${host_ip}[[:space:]]+${GITLAB_HOST}([[:space:]]+.*)?$" /etc/hosts; then
    log_warn "Entry exists for ${GITLAB_HOST} at ${host_ip}."
  else
    echo "${host_ip} ${GITLAB_HOST}" >> /etc/hosts
    log_success "Added '${host_ip} ${GITLAB_HOST}' to /etc/hosts."
  fi
}

start_docker() {
  log_info "Starting Docker Compose services..."
  docker compose up -d
  log_success "Docker Compose services started."
}

wait_for_gitlab() {
  log_info "Waiting for GitLab to become operational..."
  local timeout=900
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if curl -k -s --fail "${GITLAB_URL}/-/ready" >/dev/null; then
      log_success "GitLab is operational."
      sleep 5
      return
    fi
    echo -n "."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  log_error "GitLab did not become operational within the timeout."
}

ensure_ssh_key() {
  local ssh_dir private_key_path public_key_path key_owner key_group
  ssh_dir="$(dirname "$SSH_KEY_PATH")"
  private_key_path="${SSH_KEY_PATH%.pub}"
  public_key_path="$SSH_KEY_PATH"

  # owner/group for chmod/chown
  if [[ -n "${SUDO_USER:-}" ]]; then
    key_owner="$SUDO_USER"
    key_group="$(id -gn "$SUDO_USER")"
  else
    key_owner="$(id -un)"
    key_group="$(id -gn)"
  fi

  # ensure ~/.ssh exists
  if [[ ! -d "$ssh_dir" ]]; then
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown -R "$key_owner:$key_group" "$ssh_dir" || true
    log_info "Created $ssh_dir"
  fi

  # Both exist
  if [[ -f "$private_key_path" && -f "$public_key_path" ]]; then
    log_success "SSH key already present ($public_key_path)"
    return
  fi

  # Private exists, public missing
  if [[ -f "$private_key_path" && ! -f "$public_key_path" ]]; then
    log_info "Private key present, public missing — deriving..."
    ssh-keygen -y -f "$private_key_path" > "$public_key_path"
    chmod 644 "$public_key_path"
    chown "$key_owner:$key_group" "$public_key_path" || true
    log_success "Derived public key."
    return
  fi

  # Public exists, private missing — unsafe
  if [[ ! -f "$private_key_path" && -f "$public_key_path" ]]; then
    log_error "Public key exists but private key missing. Cannot continue safely."
  fi

  # Neither exists generate new pair
  log_info "No SSH key found — generating fresh ed25519 keypair..."
  ssh-keygen -t ed25519 -N "" -f "$private_key_path" -C "${SSH_KEY_COMMENT}@${GITLAB_HOST}"
  chmod 600 "$private_key_path"
  chmod 644 "$public_key_path"
  chown "$key_owner:$key_group" "$private_key_path" "$public_key_path" || true
  log_success "SSH keypair generated."
}

prepare_gitlab_tls() {
  local dir="${CERTS_DIR:-certs}"
  mkdir -p "${dir}"

  if [[ -f "${dir}/cert.pem" && -f "${dir}/key.pem" ]]; then
    log_success "TLS certificates already prepared in ${dir}/"
    return
  fi

  log_info "Preparing TLS certificates for host '${GITLAB_HOST}' in ${dir}/"

  if command -v mkcert >/dev/null 2>&1; then
    log_info "mkcert found; generating locally trusted certificate..."
    mkcert -install >/dev/null 2>&1 || true
    mkcert -cert-file "${dir}/cert.pem" -key-file "${dir}/key.pem" \
  "${GITLAB_HOST}" \
  "registry.${GITLAB_HOST}" \
  "gitlab-test.local" \
  "registry.gitlab-test.local" \
  127.0.0.1 ::1
  else
    if ! command -v openssl >/dev/null 2>&1; then
      log_error "Neither mkcert nor openssl is installed; cannot generate a certificate.
Install mkcert or openssl, or place cert.pem/key.pem in ${dir}/ manually."
    fi
    log_info "openssl found; generating self-signed certificate with SANs (browser may warn)..."

    local ossl_cfg
    ossl_cfg="$(mktemp)"
    cat > "${ossl_cfg}" <<EOF
[req]
default_bits       = 2048
distinguished_name = dn
prompt             = no
x509_extensions    = v3_req

[dn]
CN = ${GITLAB_HOST}

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:false
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth


[alt_names]
DNS.1 = ${GITLAB_HOST}
DNS.2 = registry.${GITLAB_HOST}
DNS.3 = gitlab-test.local
DNS.4 = registry.gitlab-test.local
IP.1  = 127.0.0.1
IP.2  = ::1
EOF

    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
      -config "${ossl_cfg}" -extensions v3_req \
      -keyout "${dir}/key.pem" -out "${dir}/cert.pem"

    rm -f "${ossl_cfg}"
  fi

  chmod 600 "${dir}/key.pem" || true
  chmod 644 "${dir}/cert.pem" || true
  log_success "Generated cert.pem and key.pem in ${dir}/"
}

prepare_data_dirs() {
  #log_info "Preparing bind-mount directory for postgres"
  #install -d -m 0700 ./postgres-data
  #chown -R 999:999 postgres-data  

  # PRODUCTION GITLAB DIRECTORIES
  log_info "Preparing bind-mount directories for GitLab (production)"

  local base="gitlab-data"

  # Create top-level dirs
  install -d -m 0755 "$base/config" "$base/logs" "$base/data"

  # Omnibus service UIDs
  local REDIS_UID=997 REDIS_GID=997
  local PROM_UID=992  PROM_GID=992
  local GIT_UID=998   GIT_GID=998

  # Logs
  install -d -m 0700 \
    "$base/logs/redis" \
    "$base/logs/alertmanager" \
    "$base/logs/prometheus"

  chown -R "$REDIS_UID:$REDIS_GID" "$base/logs/redis"
  chown -R "$PROM_UID:$PROM_GID"   "$base/logs/alertmanager" "$base/logs/prometheus"

  # Data
  install -d -m 0700 "$base/data/redis"
  chown -R "$REDIS_UID:$REDIS_GID" "$base/data/redis"

  install -d -m 0700 "$base/data/alertmanager/data"
  chown -R "$PROM_UID:$PROM_GID" "$base/data/alertmanager" "$base/data/alertmanager/data"

  install -d -m 0700 "$base/data/prometheus"
  chown -R "$PROM_UID:$PROM_GID" "$base/data/prometheus"

  # Fix stale RDB
  if [[ -f "$base/data/redis/dump.rdb" ]]; then
    chown "$REDIS_UID:$REDIS_GID" "$base/data/redis/dump.rdb"
    chmod 0600 "$base/data/redis/dump.rdb" || true
  fi

  chown root:root "$base/config"
  chmod 0755      "$base/config"

  chown "$GIT_UID:$GIT_GID" "$base/data"
  chmod 0755               "$base/data"

  # TEST POSTGRES + GITLAB DIRECTORIES
  
  #log_info "Preparing bind-mount directory for postgres-test"
  #install -d -m 0700 ./postgres-test-data
  #install -d -o 999 -g 999 -m 0700 ./postgres-test-data
  #chown -R 999:999 postgres-test-data
  
  log_info "Preparing bind-mount directories for GitLab (test)"
  
  local tbase="gitlab-test-data"
  
  # Create top-level dirs
  install -d -m 0755 "$tbase/config" "$tbase/logs" "$tbase/data"
  
  # Data
  install -d -m 0700 "$tbase/data/redis"
  chown -R "$REDIS_UID:$REDIS_GID" "$tbase/data/redis"
  
  install -d -m 0700 "$tbase/data/alertmanager/data"
  chown -R "$PROM_UID:$PROM_GID" \
      "$tbase/data/alertmanager" \
      "$tbase/data/alertmanager/data"
  
  install -d -m 0700 "$tbase/data/prometheus"
  chown -R "$PROM_UID:$PROM_GID" "$tbase/data/prometheus"
  
  # Fix stale RDB
  if [[ -f "$tbase/data/redis/dump.rdb" ]]; then
    chown "$REDIS_UID:$REDIS_GID" "$tbase/data/redis/dump.rdb"
    chmod 0600 "$tbase/data/redis/dump.rdb" || true
  fi
  
  # Config & data root permissions
  chown root:root "$tbase/config"
  chmod 0755      "$tbase/config"
  
  chown "$GIT_UID:$GIT_GID" "$tbase/data"
  chmod 0755               "$tbase/data"

  # SELinux (noop on Debian)
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    chcon -Rt svirt_sandbox_file_t "$base" "$tbase" certs || true
  fi

  log_success "All bind-mount directories prepared with correct ownerships."
}

configure_gitlab() {
  log_info "Retrieving initial root password..."
  INITIAL_PASSWORD="$(docker compose exec -T gitlab grep 'Password:' /etc/gitlab/initial_root_password | awk '{print $2}')"
  [[ -z "$INITIAL_PASSWORD" ]] && log_error "Unable to read initial root password."

  echo "$INITIAL_PASSWORD" > .gitlab_pass
  log_success "Initial password saved."

  log_info "Creating Personal Access Token (PAT)..."
  local rails_script
  read -r -d '' rails_script <<'RUBY' || true
user = User.find_by(username: 'root')
if user
  token = user.personal_access_tokens.find_by(name: 'setup-script')
  token.revoke! if token
  new_token = user.personal_access_tokens.create!(
    name: 'setup-script',
    scopes: [:api, :create_runner],
    expires_at: 365.days.from_now
  )
  puts new_token.token
end
RUBY

  PAT="$(docker compose exec -T gitlab gitlab-rails runner "$rails_script" | tail -n1 || true)"
  [[ -z "$PAT" || "$PAT" == "null" ]] && log_error "Failed to create PAT."

  echo "$PAT" > .gitlab_pat
  log_success "PAT created & saved."

  # Disable public sign-ups
  log_info "Disabling public sign-ups (ApplicationSetting.signup_enabled=false)..."
  if docker compose exec -T gitlab gitlab-rails runner "ApplicationSetting.current.update!(signup_enabled: false)"; then
    log_success "Public sign-ups disabled."
  else
    log_warn "Could not disable sign-ups via Rails runner; set it later in Admin > Settings > General."
  fi

  # Default branch global = main
  docker compose exec -T gitlab gitlab-rails runner \
    "ApplicationSetting.current.update!(default_branch_name: 'main')" >/dev/null 2>&1 || true

  # Instance-wide repo size limit
  log_info "Setting instance-wide default repository size limit to 1GB (1024 MB)..."
  if docker compose exec -T gitlab gitlab-rails runner \
    "ApplicationSetting.current.update!(repository_size_limit: 1024) ; puts ApplicationSetting.current.repository_size_limit" \
    | tail -n1 | grep -qx '1024'; then
    log_success "Instance-wide repo size limit set to 1024 MB."
  else
    log_warn "Could not confirm repo size limit change (check logs)."
  fi

  # SSH key
  log_info "Ensuring SSH key exists..."
  ensure_ssh_key

  log_info "Adding SSH public key to root account (if needed)..."
  local ssh_key_content key_exists
  ssh_key_content="$(cat "$SSH_KEY_PATH")"

  key_exists="$(SSH_KEY_VAR="$ssh_key_content" docker compose exec -T -e SSH_KEY_VAR gitlab \
      gitlab-rails runner \
      "puts User.find_by(username: 'root').keys.any? { |k| k.key == ENV['SSH_KEY_VAR'] }")"

  if [[ "$key_exists" == "true" ]]; then
    log_success "SSH key already present in GitLab root."
  else
    SSH_KEY_VAR="$ssh_key_content" docker compose exec -T -e SSH_KEY_VAR gitlab \
      gitlab-rails runner \
      "User.find_by(username: 'root').keys.create!(key: ENV['SSH_KEY_VAR'], title: 'setup-key')"
    log_success "SSH key added to root account."
  fi
}

create_group_devops() {
  log_info "Ensuring group '$DEVOPS_GROUP_NAME' exists..."
  local create_output http_code body

  create_output="$(curl -k --write-out $'\nHTTP_CODE:%{http_code}' --silent \
    --header "PRIVATE-TOKEN: $PAT" \
    -X POST "${GITLAB_URL}/api/v4/groups" \
    --data-urlencode "name=$DEVOPS_GROUP_NAME" \
    --data-urlencode "path=$DEVOPS_GROUP_PATH" \
    --data "visibility=internal")"

  http_code="$(echo "$create_output" | grep HTTP_CODE | cut -d: -f2)"
  body="$(echo "$create_output" | sed '$d')"

  if [[ "$http_code" == "201" ]]; then
    DEVOPS_GROUP_ID="$(echo "$body" | jq '.id')"
  else
    local search
    search="$(curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
        "${GITLAB_URL}/api/v4/groups?search=$DEVOPS_GROUP_NAME")"
    DEVOPS_GROUP_ID="$(echo "$search" | jq ".[] | select(.full_path==\"$DEVOPS_GROUP_PATH\").id" | head -n1)"
    [[ -z "$DEVOPS_GROUP_ID" ]] && log_error "Group creation/search failed."
  fi

  log_success "Group ready (id=$DEVOPS_GROUP_ID)."
}

create_project_mirror_in_group() {
  log_info "Ensuring mirror project exists..."
  local api_output http_code body

  api_output="$(curl -k --write-out $'\nHTTP_CODE:%{http_code}' --silent \
    --header "PRIVATE-TOKEN: $PAT" \
    -X POST "${GITLAB_URL}/api/v4/projects" \
    --data-urlencode "name=$MIRROR_PROJECT_NAME" \
    --data "namespace_id=$DEVOPS_GROUP_ID" \
    --data "default_branch=main" \
    --data "container_registry_enabled=true")"

  http_code="$(echo "$api_output" | grep HTTP_CODE | cut -d: -f2)"
  body="$(echo "$api_output" | sed '$d')"

  if [[ "$http_code" == "201" ]]; then
    MIRROR_PROJECT_ID="$(echo "$body" | jq '.id')"
  else
    local find
    find="$(curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
        "${GITLAB_URL}/api/v4/projects?search=$MIRROR_PROJECT_NAME")"
    MIRROR_PROJECT_ID="$(echo "$find" | jq \
      ".[] | select(.namespace.full_path==\"$DEVOPS_GROUP_PATH\" and .path==\"$MIRROR_PROJECT_NAME\").id" \
      | head -n1)"
    [[ -z "$MIRROR_PROJECT_ID" ]] && log_error "Mirror project creation/search failed."
  fi

  curl -k --silent --output /dev/null --request PUT \
    --header "PRIVATE-TOKEN: $PAT" \
    --data "default_branch=main" \
    "${GITLAB_URL}/api/v4/projects/${MIRROR_PROJECT_ID}"

  log_success "Mirror project ready (id=$MIRROR_PROJECT_ID)."
}

register_runner_devops_group_authflow() {
  log_info "Creating GROUP-scoped runner..."

  local gid_clean
  gid_clean="$(echo -n "$DEVOPS_GROUP_ID" | tr -d '[:space:]')"
  if ! [[ "$gid_clean" =~ ^[0-9]+$ ]]; then
    log_error "Group ID '$DEVOPS_GROUP_ID' is not a valid integer."
  fi

  local create_resp auth_token runner_id
  if ! create_resp="$(
    curl -k --silent --show-error --fail-with-body \
      --header "PRIVATE-TOKEN: $PAT" \
      --data "runner_type=group_type" \
      --data "group_id=${gid_clean}" \
      --data-urlencode "description=${DEVOPS_RUNNER_DESCRIPTION}" \
      "${GITLAB_URL}/api/v4/user/runners"
  )"; then
    log_error "Group runner creation failed. Server said: $(echo "$create_resp")"
  fi

  auth_token="$(echo "$create_resp" | jq -r '.token')"
  runner_id="$(echo "$create_resp" | jq -r '.id')"
  if [[ -z "$auth_token" || "$auth_token" == "null" ]]; then
    log_error "Failed to obtain runner authentication token. Response: $create_resp"
  fi
  log_success "Group runner $runner_id created. Registering with auth token..."

  docker compose exec -T gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "$GITLAB_URL" \
    --token "$auth_token" \
    --executor "docker" \
    --docker-image "docker:stable" \
    --docker-volumes "/var/run/docker.sock:/var/run/docker.sock"

  # Enable the runner for the mirror project so jobs can use it
  if curl -k --silent --show-error --fail-with-body \
      --request POST \
      --header "PRIVATE-TOKEN: $PAT" \
      --data "runner_id=${runner_id}" \
      "${GITLAB_URL}/api/v4/projects/${MIRROR_PROJECT_ID}/runners" >/dev/null; then
    log_success "Runner $runner_id enabled for project ${MIRROR_PROJECT_ID}."
  else
    log_warn "Could not enable runner $runner_id for project ${MIRROR_PROJECT_ID}."
  fi

  # Set tag(s) and enforce tagged-only scheduling
  if curl -k --silent --show-error --fail-with-body \
      --request PUT \
      --header "PRIVATE-TOKEN: $PAT" \
      --data "tag_list=${DEVOPS_RUNNER_TAGS}" \
      --data "run_untagged=false" \
      "${GITLAB_URL}/api/v4/runners/${runner_id}" >/dev/null; then
    log_success "Runner $runner_id updated: tags='${DEVOPS_RUNNER_TAGS}', run_untagged=false."
  else
    log_warn "Could not update tags/run_untagged for runner $runner_id; set them in the UI if needed."
  fi

  # Copy the CA cert to the runner container for TLS verification
  docker compose exec -T gitlab-runner mkdir -p /etc/gitlab-runner/certs
  docker compose cp certs/cert.pem gitlab-runner:/etc/gitlab-runner/certs/ca.crt || true

  log_success "DevOps group runner registered."
}

cleanup_known_hosts() {
  log_info "Cleaning known_hosts..."
  for kh_home in "/root" "$USER_HOME"; do
    local kh="$kh_home/.ssh/known_hosts"
    if [[ -f "$kh" ]]; then
      ssh-keygen -f "$kh" -R "[${GITLAB_HOST}]:${GITLAB_SSH_PORT}" >/dev/null 2>&1 || true
    fi
  done

  # Ensure the sudo-invoking user's ~/.ssh/known_hosts has sane perms/ownership
  local runner="${SUDO_USER:-$USER}"

  local runner_home
  if runner_home="$(getent passwd "$runner" | awk -F: '{print $6}')" && [[ -n "$runner_home" ]]; then
    :
  else
    runner_home="$(eval echo "~$runner")"
  fi

  if [[ -z "${runner_home:-}" || ! -d "$runner_home" ]]; then
    log_info "Could not resolve home directory for user '$runner'; skipping perms fix."
    return 0
  fi

  local runner_group
  runner_group="$(id -gn "$runner" 2>/dev/null || echo "$runner")"

  local ssh_dir="$runner_home/.ssh"
  mkdir -p "$ssh_dir"
  chown "$runner:$runner_group" "$ssh_dir"
  chmod 700 "$ssh_dir"

  local kh="$ssh_dir/known_hosts"
  touch "$kh"
  chown "$runner:$runner_group" "$kh"
  chmod 600 "$kh"
}

push_mirror_repo() {
  log_info "Pushing mirror project..."
  [[ ! -d "$MIRROR_LOCAL_DIR" ]] && log_error "Missing $MIRROR_LOCAL_DIR/"
  [[ ! -f "$MIRROR_LOCAL_DIR/images.txt" ]] && log_error "Missing images.txt"
  [[ ! -f "$MIRROR_LOCAL_DIR/.gitlab-ci.yml" ]] && log_error "Missing .gitlab-ci.yml"

  local private_key_path="${SSH_KEY_PATH%.pub}"

  pushd "$MIRROR_LOCAL_DIR" >/dev/null
  rm -rf .git
  git init -b main >/dev/null 2>&1 || { git init; git checkout -b main; }
  git config user.name "GitLab Admin"
  git config user.email "admin@example.com"
  git add .
  git commit -m "Initial commit for mirror project"
  git remote add origin "$MIRROR_SSH_URL"

  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i '$private_key_path'" \
    git push -u origin main || log_error "Push failed."

  curl -k --silent --output /dev/null --request PUT \
      --header "PRIVATE-TOKEN: $PAT" \
      --data "default_branch=main" \
      "${GITLAB_URL}/api/v4/projects/${MIRROR_PROJECT_ID}"

  popd >/dev/null

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER:$(id -g "$SUDO_USER")" "$MIRROR_LOCAL_DIR" || true
  fi
}

verify_pipeline_for() {
  local project_path_enc="$1"
  log_info "Verifying pipeline for $project_path_enc"

  local pipeline_id=""
  local raw=""
  
  for i in $(seq 1 360); do
    echo "DEBUG: Attempt $i"
    echo "DEBUG: Fetching pipelines from: ${GITLAB_URL}/api/v4/projects/${project_path_enc}/pipelines"

    raw="$(curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
        "${GITLAB_URL}/api/v4/projects/${project_path_enc}/pipelines")"

    echo "DEBUG: RAW RESPONSE: $raw"

    pipeline_id="$(echo "$raw" | jq -r '.[0].id // empty')"

    echo "DEBUG: Parsed pipeline_id = '$pipeline_id'"

    # break if real ID found
    if [[ -n "$pipeline_id" && "$pipeline_id" != "null" ]]; then
      break
    fi

    sleep 5
  done

  if [[ -z "$pipeline_id" || "$pipeline_id" == "null" ]]; then
    log_error "No pipeline found."
    return 1
  fi

  local elapsed=0 timeout=600 status
  while [[ $elapsed -lt $timeout ]]; do
    status="$(curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
        "${GITLAB_URL}/api/v4/projects/${project_path_enc}/pipelines/${pipeline_id}" | jq -r '.status')"

    case "$status" in
      success) log_success "Pipeline succeeded!"; return ;;
      failed)  log_error "Pipeline FAILED." ;;
      canceled|skipped) log_warn "Pipeline $status."; return ;;
      *)
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
        ;;
    esac
  done

  log_error "Pipeline timeout."
}

verify_pipeline_created_for() {
  local project_path_enc="$1"
  log_info "Checking that a pipeline was created for $project_path_enc"

  local raw pipeline_id
  raw="$(curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
        "${GITLAB_URL}/api/v4/projects/${project_path_enc}/pipelines")"

  pipeline_id="$(echo "$raw" | jq -r '.[0].id // empty')"

  if [[ -z "$pipeline_id" || "$pipeline_id" == "null" ]]; then
    log_warn "No pipeline was created (this is expected for manual-only projects)."
  else
    log_success "Pipeline record created (ID: $pipeline_id). Waiting is not required."
  fi
}

create_and_push_maint_repo() {
  log_info "Creating and pushing maint project..."

  # Ensure required files exist
  [[ ! -d "$MAINT_LOCAL_DIR" ]] && log_error "Missing $MAINT_LOCAL_DIR/"
  [[ ! -f "$MAINT_LOCAL_DIR/.gitlab-ci.yml" ]] && log_error "Missing $MAINT_LOCAL_DIR/.gitlab-ci.yml"

  # Create-or-find MAINT project
  log_info "Ensuring maint project exists..."

  local api_output http_code body

  api_output="$(curl -k --write-out $'\nHTTP_CODE:%{http_code}' --silent \
    --header "PRIVATE-TOKEN: $PAT" \
    -X POST "${GITLAB_URL}/api/v4/projects" \
    --data-urlencode "name=$MAINT_PROJECT_NAME" \
    --data "namespace_id=$DEVOPS_GROUP_ID" \
    --data "default_branch=main" \
    --data "container_registry_enabled=true"
  )"

  http_code="$(echo "$api_output" | grep HTTP_CODE | cut -d: -f2)"
  body="$(echo "$api_output" | sed '$d')"

  if [[ "$http_code" == "201" ]]; then
    MAINT_PROJECT_ID="$(echo "$body" | jq -r '.id')"
  else
    local found
    found="$(curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
      "${GITLAB_URL}/api/v4/projects?search=$MAINT_PROJECT_NAME"
    )"

    MAINT_PROJECT_ID="$(
      echo "$found" | jq -r \
        ".[] | select(.namespace.full_path==\"$DEVOPS_GROUP_PATH\" and .path==\"$MAINT_PROJECT_NAME\").id"
    )"

    [[ -z "$MAINT_PROJECT_ID" ]] && log_error "Maint project creation/search failed."
  fi

  # Ensure default branch is set to main
  curl -k --silent --output /dev/null --request PUT \
    --header "PRIVATE-TOKEN: $PAT" \
    --data "default_branch=main" \
    "${GITLAB_URL}/api/v4/projects/${MAINT_PROJECT_ID}"

  log_success "Maint project ready (id=$MAINT_PROJECT_ID)."

  # Push local maint repo via SSH
  log_info "Pushing maint repository..."

  local private_key_path="${SSH_KEY_PATH%.pub}"

  pushd "$MAINT_LOCAL_DIR" >/dev/null

  rm -rf .git
  git init -b main >/dev/null 2>&1 || { git init; git checkout -b main; }
  git config user.name "GitLab Admin"
  git config user.email "admin@example.com"
  git add .
  git commit -m "Initial commit for maint project"
  git remote add origin "$MAINT_SSH_URL"

  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i '$private_key_path'" \
    git push -u origin main || log_error "Push failed for maint project."

  popd >/dev/null

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER:$(id -g "$SUDO_USER")" "$MAINT_LOCAL_DIR" || true
  fi

  log_success "Maint project pushed successfully."

  # Validate: pipeline *exists*
  verify_pipeline_created_for "${DEVOPS_GROUP_PATH}%2F${MAINT_PROJECT_NAME}"
}

setup_client_tls_and_auth() {
  if [[ "$SETUP_CLIENT_TLS" != "true" ]]; then
    return
  fi
  log_info "Configuring local Docker client to trust the GitLab registry..."

  local cert_file="./certs/cert.pem"
  local sys_cert_dir="/usr/local/share/ca-certificates"
  local sys_cert_name="${GITLAB_HOST}.crt"
  local sys_cert_path="${sys_cert_dir}/${sys_cert_name}"

  log_info "Installing self-signed certificate into system trust store..."
  mkdir -p "$sys_cert_dir"
  if cp "$cert_file" "$sys_cert_path"; then
    log_success "Certificate copied to $sys_cert_path"
  else
    log_error "Failed to copy certificate to $sys_cert_path"
  fi

  if update-ca-certificates; then
    log_success "System certificates updated."
  else
    log_warn "update-ca-certificates had some warnings, but may still work."
  fi

  log_info "Restarting Docker daemon to load new certificates..."
  if systemctl restart docker; then
    log_success "Docker daemon restarted."
    sleep 2
    log_info "Waiting for GitLab to come back online..."
    local timeout=300
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
      if curl -k -s --fail "${GITLAB_URL}/-/ready" >/dev/null 2>&1; then
        log_success "GitLab is back online."
        break
      fi
      sleep 5
      elapsed=$((elapsed + 5))
    done
    if [[ $elapsed -ge $timeout ]]; then
      log_warn "GitLab did not come back online within 5 minutes. It may still be starting up."
    fi
  else
    log_error "Failed to restart Docker. Try: sudo systemctl restart docker"
  fi
  
  log_info "Authenticating Docker with GitLab registry..."

  local registry_url="https://${GITLAB_HOST}:${GITLAB_REGISTRY_PORT}"

  if echo "$PAT" | docker login "$GITLAB_HOST:$GITLAB_REGISTRY_PORT" -u gitlab-ci-token -p "$(cat .gitlab_pat)" 2>/dev/null; then
    log_success "Docker client authenticated to the registry."
    log_info "Attempting to pull test image to verify credentials..."
    if docker pull "$GITLAB_HOST:$GITLAB_REGISTRY_PORT/devops/mirror/alpine:latest" >/dev/null 2>&1; then
      log_success "Successfully pulled test image from registry."
    else
      log_warn "Authenticated but failed to pull image. Check registry access and TLS setup."
    fi
  else
    log_warn "Docker credentials issue."
  fi  
}

install_host_admin_runner_if_missing() {
  log_info "Checking for existing host-admin shell runner..."

  local RUNNER_DESCRIPTION="host-admin-shell-runner"
  local RUNNER_TAGS="host-admin"

  # Check if group already has this runner
  local EXISTING_RUNNER_ID
  EXISTING_RUNNER_ID="$(
    curl -ks --header "PRIVATE-TOKEN: $PAT" \
      "${GITLAB_URL}/api/v4/groups/${DEVOPS_GROUP_ID}/runners" |
      jq -r ".[] | select(.description == \"${RUNNER_DESCRIPTION}\") | .id"
  )"

  if [[ -n "$EXISTING_RUNNER_ID" ]]; then
    log_success "Host-admin runner already exists (id=$EXISTING_RUNNER_ID). Skipping install."
    return
  fi

  log_warn "Host-admin runner not found — performing full clean install."

  # Stop + uninstall existing service
  systemctl stop gitlab-runner 2>/dev/null || true
  gitlab-runner uninstall 2>/dev/null || true

  # Install binary if missing
  if ! command -v gitlab-runner >/dev/null 2>&1; then
    log_info "Installing gitlab-runner binary..."
    curl -L --output gitlab-runner \
      https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64
    install -m 755 gitlab-runner /usr/local/bin/gitlab-runner
    rm -f gitlab-runner
  else
    log_info "gitlab-runner binary already installed at: $(command -v gitlab-runner)"
  fi

  # Install root-runner service
  log_info "Installing root-based gitlab-runner systemd service..."
  gitlab-runner install --user=root --working-directory=/root

  systemctl daemon-reload
  systemctl enable gitlab-runner
  systemctl start gitlab-runner

  # WAIT for service init
  log_info "Waiting for gitlab-runner service to initialize..."
  for i in {1..30}; do
    [[ -d /root/.gitlab-runner ]] && break
    sleep 1
  done

  # CREATE runner via API with group scope and get registration token
  log_info "Creating group-scoped runner..."
  local CREATE_RUNNER_RESP REG_TOKEN RUNNER_ID

  CREATE_RUNNER_RESP="$(
    curl -ks --fail \
      --header "PRIVATE-TOKEN: $PAT" \
      --data "runner_type=group_type" \
      --data "group_id=${DEVOPS_GROUP_ID}" \
      --data-urlencode "description=${RUNNER_DESCRIPTION}" \
      "${GITLAB_URL}/api/v4/user/runners"
  )"

  REG_TOKEN=$(echo "$CREATE_RUNNER_RESP" | jq -r '.token')
  RUNNER_ID=$(echo "$CREATE_RUNNER_RESP" | jq -r '.id')

  [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]] &&
      log_error "Failed to create runner via API."

  # REGISTER runner
  log_info "Registering host-admin runner (id=$RUNNER_ID)..."

  gitlab-runner register \
    --non-interactive \
    --url "$GITLAB_URL" \
    --token "$REG_TOKEN" \
    --executor "shell"

  # TAG + LOCK runner via API to prevent accidental use by non-admin jobs
  curl -ks --request PUT \
    --header "PRIVATE-TOKEN: $PAT" \
    --data-urlencode "tag_list=${RUNNER_TAGS}" \
    --data "run_untagged=false" \
    --data "locked=true" \
    "${GITLAB_URL}/api/v4/runners/${RUNNER_ID}" >/dev/null

  log_info "Restarting gitlab-runner service..."
  systemctl restart gitlab-runner

  log_success "Host-admin runner created, registered, tagged, and active."
}

wait_for_gitlab_api_json() {
  log_info "Waiting for GitLab API to return JSON..."
  for i in {1..30}; do
    if curl -k --silent --header "PRIVATE-TOKEN: $PAT" \
      "${GITLAB_URL}/api/v4/version" | jq -e '.version' >/dev/null 2>&1; then
      log_success "GitLab API is returning JSON."
      return
    fi
    sleep 2
  done
  log_error "GitLab API did not stabilize (non-JSON responses persist)."
}
``

summary() {
  echo ""
  log_success "GitLab Environment Setup Complete"
  log_success ""
  echo -e " ${GREEN}GitLab URL:${NC} $GITLAB_URL"
  echo -e " ${GREEN}Registry URL:${NC} $GITLAB_HOST:$GITLAB_REGISTRY_PORT"
  echo -e " ${GREEN}Username:${NC} root"
  echo -e " ${GREEN}API Token (PAT):${NC} $(cat .gitlab_pat)"
  echo -e " ${GREEN}root password:${NC} $(cat .gitlab_pass)"
  echo -e " ${GREEN}DevOps Group:${NC} $GITLAB_URL/$DEVOPS_GROUP_PATH"
  echo -e " ${GREEN}Mirror Project:${NC} $GITLAB_URL/$DEVOPS_GROUP_PATH/$MIRROR_PROJECT_NAME"
  echo -e " ${GREEN}Docker Login Command:${NC} docker login $GITLAB_HOST:$GITLAB_REGISTRY_PORT -u gitlab-ci-token -p \"$(cat .gitlab_pat)\""
  echo -e " ${GREEN}Docker Pull Command:${NC} docker pull $GITLAB_HOST:$GITLAB_REGISTRY_PORT/devops/mirror/alpine:latest"
  echo -e " ${GREEN}Runner Tags:${NC} $DEVOPS_RUNNER_TAGS"
  echo -e " ${GREEN}SSH Command:${NC} ssh -T git@$GITLAB_HOST -p $GITLAB_SSH_PORT"
  log_success "────────────────────────────────────────────────────────────────────────────"
}

main
