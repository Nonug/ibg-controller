# ibg-controller image recipe.
#
# Extends a gnzsnz/ib-gateway base with the ibg-controller artifacts
# (agent jar + Python controller) and swaps upstream's run.sh for the
# controller-aware variant shipped alongside.
#
# UPSTREAM_IMAGE defaults to the SAME digest-pinned base the release
# workflow publishes, so a bare `docker build .` reproduces the shipped
# image. This is the single source of truth for the pin — release-image.yml
# passes no build args and inherits these defaults. Bump both ARGs together.
#
# It used to default to the moving `:stable` tag, which was a trap: a bare
# build silently picked up whatever `:stable` happened to be in the local
# cache (a five-month-old base, in one 2026-09-07 pre-release spike) and
# labelled it `unknown`, so a maintainer could "validate" a version that
# never ran.
#
# Any gnzsnz base works, including their `latest` channel if you want a
# newer Gateway than the stable line carries (issue #24). This layer is
# three apt packages and four COPYs, so it is a pull plus about a
# minute, not a rebuild of the upstream image:
#
#   docker build -t ibg-controller:edge \
#     --build-arg UPSTREAM_IMAGE=ghcr.io/gnzsnz/ib-gateway:<tag> \
#     --build-arg IB_GATEWAY_VERSION=<tag> .
#
# Pass the same tag to both ARGs so the version label matches the base;
# IB_GATEWAY_VERSION is a label only — nothing in the build reads it.
#
# CI builds against that line too, but only as a build-and-boot check —
# login/2FA/dialog behaviour was validated on the 10.45.x line, except the
# passkey flow, which was validated end-to-end on the pinned 10.50.1e base.
#
# Build prerequisites: run `make` in the repo root first to populate
# dist/ with the agent jar and the controller .py, then `docker build .`
# from the same directory.

ARG UPSTREAM_IMAGE=ghcr.io/gnzsnz/ib-gateway:10.50.1e@sha256:e340626b5569d476bb96f891b5435ec9b9da517afd1e03c71e73fc50188477b1
FROM ${UPSTREAM_IMAGE}

# Re-declare post-FROM so they're in scope for the LABEL below (a build ARG
# declared before FROM is only visible to the FROM instruction itself).
ARG UPSTREAM_IMAGE
ARG IB_GATEWAY_VERSION=10.50.1e

# Self-describing image: record the bundled IB Gateway version and the exact
# upstream base so `docker inspect` (and the GHCR page) report them without
# starting the container. The release workflow passes the real
# IB_GATEWAY_VERSION, kept in lockstep with the digest-pinned UPSTREAM_IMAGE;
# local builds that don't set it report "unknown".
LABEL com.ibg-controller.ib-gateway-version="${IB_GATEWAY_VERSION}" \
      org.opencontainers.image.base.name="${UPSTREAM_IMAGE}"

USER root

# Runtime packages. `gettext-base socat xvfb x11vnc sshpass openssh-client
# sudo telnet` are already in the upstream image; listed nowhere here
# because the upstream provides them. We add:
#   - python3: runs gateway_controller.py.
#   - matchbox-window-manager: Xvfb has no concept of focused window
#     without a WM, and Gateway's input routing depends on focus.
#   - curl: used by scripts/healthcheck.sh.
RUN apt-get update -y \
 && apt-get install --no-install-recommends --yes \
      python3 matchbox-window-manager curl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Install the controller artifacts from the local build. Run `make` before
# `docker build` so dist/ is populated.
COPY dist/gateway-input-agent.jar /home/ibgateway/gateway-input-agent.jar
COPY dist/gateway_controller.py  /home/ibgateway/scripts/gateway_controller.py

# Swap in the controller-aware run.sh. Replaces upstream's IBC-first
# dispatch with a path that starts the controller, waits for its
# readiness signal, then brings up socat port forwarding.
COPY docker/run.sh /home/ibgateway/scripts/run.sh

# Healthcheck shim — curls the controller's /health endpoint on the
# configured port (and on the paper-side offset port when DUAL_MODE=yes).
# Used by the HEALTHCHECK directive below.
COPY scripts/healthcheck.sh /home/ibgateway/scripts/healthcheck.sh

# Root entrypoint + passless hidraw bridge. See scripts/entrypoint.sh:
# the image starts as root so a hook can mknod the passless virtual
# FIDO2 node (no udev in containers), then drops to uid 1000. Opt-in via
# PASSKEY_HIDRAW_BRIDGE=yes; harmless when unused.
COPY scripts/entrypoint.sh   /home/ibgateway/scripts/entrypoint.sh
COPY scripts/hidraw-watch.sh /home/ibgateway/scripts/hidraw-watch.sh

# Default port for the /health HTTP server the controller starts in
# main(). docker/run.sh offsets the paper instance to base+1 when
# DUAL_MODE=yes so both controllers can bind in the same container.
# Override with --env CONTROLLER_HEALTH_SERVER_PORT=0 to disable.
ENV CONTROLLER_HEALTH_SERVER_PORT=8080 \
    CONTROLLER_HEALTH_SERVER_HOST=0.0.0.0

RUN chown -R 1000:1000 /home/ibgateway \
 && chmod 0755 /home/ibgateway/scripts/run.sh \
 && chmod 0755 /home/ibgateway/scripts/gateway_controller.py \
 && chmod 0755 /home/ibgateway/scripts/healthcheck.sh \
 && chmod 0755 /home/ibgateway/scripts/entrypoint.sh \
 && chmod 0755 /home/ibgateway/scripts/hidraw-watch.sh \
 && chmod 0644 /home/ibgateway/gateway-input-agent.jar

# start-period gives the JVM + login pipeline time to finish before
# failures count. The controller's /health returns 503 (not 200) during
# login, so without the grace window a fresh container would be marked
# unhealthy for ~2min during normal boot.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD /home/ibgateway/scripts/healthcheck.sh

# Starts as root so entrypoint.sh can run the opt-in hidraw bridge, then
# drops privileges to 1000:1000 before exec'ing run.sh. Upstream ran as
# 1000 from the start; the drop now happens one step later.
USER root
WORKDIR /home/ibgateway
ENTRYPOINT ["/home/ibgateway/scripts/entrypoint.sh"]
CMD ["/home/ibgateway/scripts/run.sh"]
