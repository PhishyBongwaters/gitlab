# Container Image Mirror

This project mirrors selected container images into this project's GitLab Container Registry and prunes anything not listed in `images.txt`.

## How it works

The `mirror` job in `.gitlab-ci.yml` does four things in one run:

1. Reads `images.txt`.
2. Mirrors each listed source image to `$CI_REGISTRY_IMAGE/<target>`.
3. Lists all tags currently present in this project's registry and deletes tags that are not in `images.txt`.
4. Deletes repositories that become empty after tag cleanup (GitLab may show these as scheduled for deletion).

## Pipeline triggers

The job runs when:

- A push modifies `images.txt`.
- A scheduled pipeline runs.
- A pipeline is started manually from the web UI.

## `images.txt` format

Each non-empty, non-comment line must be:

```txt
<target-name:tag>=<source-image-reference>
```

- `<target-name:tag>`: destination name+tag under this project registry.
- `<source-image-reference>`: source image to copy.
- If source has no registry host, Docker Hub is assumed.

## Examples:
| Source Image | Mirror Target |
|--------------|---------------|
| nginx:1.27=library/nginx:1.27 | $CI_REGISTRY_IMAGE/nginx:1.27 |
| postgres:production=library/postgres@sha256:sha256_hash | $CI_REGISTRY_IMAGE/postgres:production |

## Authentication notes

- Copy/push and default API calls use `CI_JOB_TOKEN`.

## Consuming Mirrored Images

### Prerequisites

The GitLab Container Registry uses a self-signed certificate. Docker must trust the registry certificate before authentication and pulls will work.

Install the registry certificate:

```bash
sudo mkdir -p /etc/docker/certs.d/gitlab.nbcc.ca:5005
sudo cp cert.pem /etc/docker/certs.d/gitlab.nbcc.ca:5005/ca.crt
sudo systemctl restart docker
```

## Authenticate to Registry
```bash
docker login gitlab.nbcc.ca:5005
user:devops
password:devops-token
```

## Pull an image
```bash
docker pull gitlab.nbcc.ca:5005/devops/mirror/alpine:latest
```
