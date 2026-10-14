systemctl stop gitlab-runner
curl -L --output gitlab-runner "https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/latest/binaries/gitlab-runner-linux-amd64"
systemctl start gitlab-runner
