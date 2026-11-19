# garrett, the Sentinel agent, for container hosts: the image each release publishes (ghcr.io/<owner>/garrett).
# It is deploy/Dockerfile with the release's own program in it instead of a fresh build: the statically linked
# garrett-linux-<processor> of the image's processor, so one release gives the same program in every form.
# The release workflow builds it from a folder holding those three files and deploy/entrypoint.sh:
#   linux/garrett-linux-x86_64, linux/garrett-linux-aarch64, linux/garrett-linux-armv7, entrypoint.sh
FROM debian:stable-slim
ARG TARGETARCH
ARG TARGETVARIANT
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 nftables ca-certificates && rm -rf /var/lib/apt/lists/*
COPY linux/ /tmp/linux/
RUN case "$TARGETARCH$TARGETVARIANT" in \
      amd64) processor=x86_64 ;; \
      arm64) processor=aarch64 ;; \
      armv7) processor=armv7 ;; \
      *) echo "No garrett for $TARGETARCH$TARGETVARIANT" >&2; exit 1 ;; \
    esac \
 && install -D -m 0755 "/tmp/linux/garrett-linux-$processor" /opt/sentinel/garrett \
 && rm -rf /tmp/linux \
 && /opt/sentinel/garrett version
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
