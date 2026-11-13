# One Dockerfile, four small images (build targets): device, client, relay, scanner.
# Everything is pinned: the Debian base by digest, NoPorts by version + SHA-256.

ARG DEBIAN=debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# ---- fetch the official NoPorts release tarball and check its checksum ------
FROM ${DEBIAN} AS fetch
ARG TARGETARCH
ARG NOPORTS_VERSION=v5.18.2
# SHA-256s from the release's checksums.txt
ARG SHA_X64=210e5f6afdde7bec40927fb3127be9d34f9a924265695f7c05926c6008d36c8e
ARG SHA_ARM64=ea3a3dd668aa617d8f00d7ed5b82ab6c325ea8dd2a9604ed45f8695a3eadae23
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) A=x64;   SHA=$SHA_X64 ;; \
      arm64) A=arm64; SHA=$SHA_ARM64 ;; \
      *) echo "Unsupported CPU architecture: $TARGETARCH (need amd64 or arm64)"; exit 1 ;; \
    esac; \
    curl -fsSL -o /np.tgz "https://github.com/atsign-foundation/noports/releases/download/${NOPORTS_VERSION}/sshnp-linux-${A}.tgz"; \
    echo "$SHA  /np.tgz" | sha256sum -c -; \
    tar xzf /np.tgz -C /opt

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
