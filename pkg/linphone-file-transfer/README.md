# Linphone file transfer

A standalone HTTPS service for Linphone attachment uploads and downloads and the
public provisioning XML. The upload descriptor uses the GSMA RCS HTTP file
transfer namespace. `--public-origin` controls advertised links regardless of
request headers or the internal listener. The service does not implement
outbound federation/proxying or client-certificate authentication.

```
linphone-file-transfer credentials --realm sip.example.org \
  --output /run/linphone-file-transfer-credentials/accounts.json \
  --account alice=/run/secrets/alice-sip-password

linphone-file-transfer serve --listen 127.0.0.1:8443 \
  --tls-cert /run/tls/fullchain.pem --tls-key /run/tls/key.pem \
  --public-origin https://files.example.org --realm sip.example.org \
  --credentials /run/linphone-file-transfer-credentials/accounts.json \
  --provisioning /etc/linphone-config.xml \
  --uploads /var/lib/flexisip-file-transfer \
  --database /var/lib/linphone-file-transfer/attachments.sqlite \
  --max-bytes 33554432 --retention-seconds 604800
```

Pass `--conference-provisioning FILE --conference-path PATH` together to expose
an optional second provisioning document. Both provisioning documents support
GET/HEAD. The service uses TLS 1.2 or newer, with credentials, provisioning and
TLS certificate loaded at startup; restart it to reload those inputs. It does
not log requests.

`credentials` strips all CR/LF from password files, matching the Flexisip
account loader. It atomically replaces the output with a new mode-0640 file
containing only MD5 and SHA-256 Digest HA1 values. Treat the manifest as a
secret; provision it in a private runtime directory and ensure the service can
read it (e.g. systemd `LoadCredential`). Change the group externally if needed.
Upload and download accept Digest `Authorization` or Linphone `Auth-Digest`,
with `qop=auth`. Nonces expire after two minutes and accepted nonce counts
cannot be reused. The `From` header confers no authority. An authenticated
account can retrieve any attachment whose unguessable URL it has, preserving
the attachment-sharing behavior of the previous endpoint.

Keep the SQLite database (including SQLite's sidecars) outside the uploads
root. There should be one server writer and no external cleanup job while it
is running. New completed attachments are limited to 4,096 records and 128
times `--max-bytes` in aggregate, plus at most eight staged uploads in flight
(up to one file byte beyond the per-file limit to detect oversized uploads).
The server bounds parallel downloads at 32. It sweeps expired uploads and
abandoned staging files at startup and periodically (at least every minute).

Legacy PHP files are recognized only as lowercase `13hex_20hex.extension`,
with a 1–32 byte ASCII extension (`a-z`, `0-9`, `_`, `-`), an optional `.txt`
safety suffix, or a lone dot when the original upload had no extension. Only
regular, singly linked legacy files inside the uploads root are served; their
retention is measured from mtime. Legacy data does not count against the new
metadata quota and expires in place. Files such as old logs are neither served
nor pruned. New attachments use `13hex_20hex.bin` so the prior PHP service can
find and serve them after rollback (with existing filesystem ownership
restored). The human-facing name and MIME type are in the descriptor, not in
the generated disk filename.

The package uses Go plus a small cgo adapter for system SQLite; it downloads
no Go modules. Its tests exercise the HTTP handlers in process and use both
an in-memory index and scratch on-disk SQLite.
