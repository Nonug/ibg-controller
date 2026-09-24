#!/bin/bash
# Container entrypoint.
#
# The image previously ran as uid 1000 from the start, which meant
# /home/ibgateway/START_SCRIPTS could never create device nodes. The
# passkey bridge needs exactly that: a root hook that mknods the
# passless hidraw node (containers don't run udev) before Gateway starts.
#
# So: start as root, optionally start the hidraw watcher, then drop to
# the unprivileged ibgateway user and exec the real command (run.sh).
# With PASSKEY_HIDRAW_BRIDGE unset the only change is that the privilege
# drop happens here instead of via the image's USER directive.
#
# Env:
#   PASSKEY_HIDRAW_BRIDGE=yes   start scripts/hidraw-watch.sh as root
#   IBGATEWAY_UID / IBGATEWAY_GID  target ids (default 1000)

set -Eeo pipefail

if [ "$(id -u)" = "0" ]; then
	if [ "${PASSKEY_HIDRAW_BRIDGE:-}" = "yes" ]; then
		/home/ibgateway/scripts/hidraw-watch.sh &
	fi

	exec setpriv \
		--reuid="${IBGATEWAY_UID:-1000}" \
		--regid="${IBGATEWAY_GID:-1000}" \
		--init-groups \
		--inh-caps=-all --ambient-caps=-all \
		-- "$@"
fi

exec "$@"
