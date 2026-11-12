# The sandbox image: the tools an agent needs to work on a repository, and nothing more.
#
# What is here and why:
#   git            clone, branch, commit, diff — the work itself
#   node + npm     build and test JavaScript/TypeScript repositories
#   python3 + pip  build and test Python repositories
#   bash, coreutils, findutils  real shell work
#   ripgrep, jq, less, nano     read, search and inspect what is there
#   ca-certificates, openssl    TLS verification for git over HTTPS
#   tini           reaps orphan processes so a long run cannot leak zombies
#
# What is deliberately NOT here:
#   no docker/podman inside (a sandbox must not be able to start a sibling)
#   no compilers for C/C++ beyond what alpine ships (keeps the image small)
#   no ssh client keys, no cloud CLIs, no credentials of any kind
#
# The container still runs as uid 1000, without extra capabilities, with no host mounts
# and no network unless a phase opens it.
FROM alpine:3.20

RUN apk add --no-cache \
      git \
      bash \
      nodejs \
      npm \
      python3 \
      py3-pip \
      coreutils \
      findutils \
      ripgrep \
      jq \
      less \
      nano \
      curl \
      ca-certificates \
      openssl \
      tini \
 && update-ca-certificates

# git needs an identity to commit; a demo identity is better than a confusing failure.
RUN git config --system user.name "MovilClaw Sandbox" \
 && git config --system user.email "sandbox@movilclaw.invalid" \
 && git config --system --add safe.directory /work

# A non-root user that matches the --user flag the orchestrator passes.
RUN adduser -D -u 1000 sandbox \
 && mkdir -p /work \
 && chown -R sandbox:sandbox /work

USER sandbox
WORKDIR /work

# Overridden by the orchestrator; it exists so the image is runnable on its own.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/sh", "-c", "sleep infinity"]
