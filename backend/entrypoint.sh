#!/bin/sh
set -eu
# Ephemeral target certificate: ALB encrypts traffic but does not verify target certificates.
# Security groups admit only the ALB. The key never leaves this task's writable /tmp.
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /tmp/target.key -out /tmp/target.crt -subj '/CN=ecs-target' >/dev/null 2>&1
exec uvicorn app.main:app --host 0.0.0.0 --port 8443 \
  --ssl-keyfile /tmp/target.key --ssl-certfile /tmp/target.crt \
  --no-access-log --no-proxy-headers --timeout-graceful-shutdown 130
