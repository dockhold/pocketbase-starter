# PocketBase on Dockhold.
#
# PocketBase is MIT licensed (see README). This image is the upstream release
# binary plus a start script that wires it to Dockhold's port, App storage,
# and your admin account. Nothing is compiled here: the first stage downloads
# the release zip and checks it against the sha256 pinned below, the second
# stage is a plain Alpine with the binary and this repo's folders.
#
# Upgrading: change PB_VERSION and PB_SHA256 together. The sha256 is the
# pocketbase_<version>_linux_amd64.zip line of checksums.txt on the matching
# release page: https://github.com/pocketbase/pocketbase/releases
# A wrong or stale sha256 fails the build. That is the point.

ARG ALPINE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

FROM ${ALPINE} AS download
ARG PB_VERSION=0.40.4
ARG PB_SHA256=9042ec818570e79c3628dadcd0a756c1496d9e1173918ec409d133c02f82e5fa
RUN apk add --no-cache ca-certificates curl unzip \
 && curl -fsSL -o /tmp/pocketbase.zip \
      "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip" \
 && echo "${PB_SHA256}  /tmp/pocketbase.zip" | sha256sum -c - \
 && mkdir -p /out \
 && unzip -q /tmp/pocketbase.zip pocketbase LICENSE.md -d /out \
 && chmod 0755 /out/pocketbase \
 && /out/pocketbase --version | grep -Fx "pocketbase version ${PB_VERSION}"

FROM ${ALPINE}
# ca-certificates so PocketBase can send email and reach S3 backups over TLS.
RUN apk add --no-cache ca-certificates
COPY --from=download /out/pocketbase /app/pocketbase
COPY --from=download /out/LICENSE.md /app/LICENSE.pocketbase.md
# The repo's folders. Root-owned and read-only at runtime: hooks and
# migrations are inputs that come from git, never from the running app.
COPY pb_hooks /app/pb_hooks
COPY pb_migrations /app/pb_migrations
COPY pb_public /app/pb_public
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh
USER 1001:1001
# The start script execs PocketBase, so it is the main process and receives
# the stop signal directly. PocketBase is a static binary with no children.
ENTRYPOINT ["/app/entrypoint.sh"]
