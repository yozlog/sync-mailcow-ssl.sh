#!/bin/bash
set -euo pipefail

CERTS_CHANGED=0

# Helper function to sync a certificate
sync_cert() {
  local src_dir="$1"
  local dst_dir="$2"
  local domain_name="$3"

  if [[ ! -f "$src_dir/fullchain.pem" ]]; then
    echo "Warning: Source certificate not found at $src_dir/fullchain.pem" >&2
    return 0
  fi

  mkdir -p "$dst_dir"

  if ! cmp -s "$src_dir/fullchain.pem" "$dst_dir/cert.pem"; then
    echo "Updating certificate for $dst_dir..."
    cp "$src_dir/fullchain.pem" "$dst_dir/cert.pem"
    cp "$src_dir/key.pem" "$dst_dir/key.pem"
    # Correct permissions
    chmod 644 "$dst_dir/cert.pem"
    chmod 600 "$dst_dir/key.pem"
    CERTS_CHANGED=1
  fi

  # Always ensure the "domains" file exists and is correct for Dovecot/Postfix SNI generation
  if [[ ! -f "$dst_dir/domains" ]] || [[ "$(cat "$dst_dir/domains" 2>/dev/null)" != "$domain_name" ]]; then
    echo "$domain_name" >"$dst_dir/domains"
    chmod 644 "$dst_dir/domains"
    CERTS_CHANGED=1
  fi
}

# 1. Sync default mail certificate (mail.domain1.com)
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain1.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl" \
  "mail.domain1.com"

# 2. Sync mail.domain1.com SNI certificate (specific folder)
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain1.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain1.com" \
  "mail.domain1.com"

# 3. Sync mail.domain2.com SNI certificate
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain2.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain2.com" \
  "mail.domain2.com"

# 4. Sync mail.domain3.com SNI certificate
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain3.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain3.com" \
  "mail.domain3.com"

# Restart services if any certificate or metadata changed
if [[ "$CERTS_CHANGED" -eq 1 ]]; then
  echo "Certificates or domains metadata updated. Restarting Mailcow Postfix, Dovecot, and Nginx..."
  docker restart mailcow-postfix mailcow-dovecot mailcow-nginx
  echo "Mailcow SSL sync completed successfully!"
else
  echo "All certificates and metadata are up to date. No action required."
fi
