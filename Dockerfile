# One Dockerfile, five small images (build targets): device, client, relay,
# scanner, and ui (the optional web page).
# NoPorts comes from the official release tarball, checked against the
# release's own checksums.txt. NOPORTS_VERSION is a tag such as v5.18.2, or
# "latest" (demo.sh resolves "latest" to a tag before building, so a new
# release means a fresh build rather than a stale cached one).

ARG DEBIAN=debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# ---- fetch the NoPorts release tarball and verify it --------------------------
FROM ${DEBIAN} AS fetch
ARG TARGETARCH
ARG NOPORTS_VERSION=latest
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) A=x64 ;; \
      arm64) A=arm64 ;; \
      *) echo "Unsupported CPU architecture: $TARGETARCH (need amd64 or arm64)"; exit 1 ;; \
    esac; \
    rel=https://github.com/atsign-foundation/noports/releases; \
    v="$NOPORTS_VERSION"; \
    if [ "$v" = latest ]; then \
      v=$(curl -fsSI "$rel/latest" | sed -n 's|^[Ll]ocation: .*/tag/\([^[:space:]]*\).*|\1|p'); \
    fi; \
    [ -n "$v" ] || { echo "Could not find the latest NoPorts release on GitHub"; exit 1; }; \
    echo "NoPorts $v, linux-$A"; \
    curl -fsSL -o /np.tgz "$rel/download/$v/sshnp-linux-$A.tgz"; \
    curl -fsSL -o /checksums.txt "$rel/download/$v/checksums.txt"; \
    sum=$(awk -v f="sshnp-linux-$A.tgz" '$2 == f {print $1}' /checksums.txt); \
    [ -n "$sum" ] || { echo "sshnp-linux-$A.tgz is not in checksums.txt"; exit 1; }; \
    echo "$sum  /np.tgz" | sha256sum -c -; \
    tar xzf /np.tgz -C /opt; \
    echo "$v" > /opt/sshnp/VERSION

# ---- common base: NoPorts binaries + a normal user called "demo" ------------
# ca-certificates: the platform's TLS certificate chains to a public CA.
FROM ${DEBIAN} AS noports
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates iproute2 procps \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash demo \
 && install -d -o demo -g demo -m 700 /home/demo/.atsign /home/demo/.atsign/keys
COPY --from=fetch /opt/sshnp/sshnpd /opt/sshnp/sshnp /opt/sshnp/npt /opt/sshnp/srvd \
                  /opt/sshnp/srv /opt/sshnp/at_activate /usr/local/bin/
COPY --from=fetch /opt/sshnp/VERSION /etc/noports-version
COPY scripts/in-container/ /usr/local/bin/

# ---- device: sshd on loopback only, plus the NoPorts daemon -----------------
FROM noports AS device
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && usermod -p '*' demo \
 && install -d -o demo -g demo -m 700 /home/demo/.ssh \
 && install -o demo -g demo -m 600 /dev/null /home/demo/.ssh/authorized_keys
COPY device/sshd_config /etc/ssh/sshd_config
CMD ["device-start"]

# ---- client: ssh client + NoPorts client ------------------------------------
FROM noports AS client
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*
USER demo
CMD ["sleep", "infinity"]

# ---- relay: the socket rendezvous (srvd) -------------------------------------
FROM noports AS relay
USER demo
CMD ["relay-start"]

# ---- scanner: just nmap ------------------------------------------------------
FROM ${DEBIAN} AS scanner
RUN apt-get update && apt-get install -y --no-install-recommends nmap \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]

# ---- ui: serves the demo as a web page (optional; "./demo.sh web") ----------
# Python for the small web server, and the Docker CLI with Compose so the
# server can run demo.sh, which runs commands in the other boxes. The server
# and the page are not copied in: the repository is mounted at /demo.
FROM ${DEBIAN} AS ui
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 docker-cli docker-compose \
 && rm -rf /var/lib/apt/lists/*
EXPOSE 8080
