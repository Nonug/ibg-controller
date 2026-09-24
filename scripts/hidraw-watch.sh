#!/bin/bash
# Bridge the passless virtual FIDO2 token's hidraw node into this
# container's /dev.
#
# Passless creates a virtual HID device via /dev/uhid; the kernel then
# creates a /dev/hidrawN node on the host. Containers do not run udev, so
# that node never appears inside this container and Gateway's embedded
# Chromium (JxBrowser) cannot open it — WebAuthn then either finds no
# authenticator or fails to assert.
#
# This runs as root before privileges are dropped (see entrypoint.sh) and
# polls sysfs, creating/refreshing the node whenever passless (re)starts.
# The device minor is kernel-allocated and changes on every passless
# restart, which is why this cannot be a static `devices:` mapping.
#
# Requires: CAP_MKNOD (Docker default), a device_cgroup_rules entry for
# the hidraw major on the Gateway container, and /sys mounted (default).
#
# Env:
#   PASSKEY_HIDRAW_MATCH   uevent substring to match (default "Virtual FIDO2")
#   PASSKEY_HIDRAW_UID     owner of the created node (default 1000)
#   PASSKEY_HIDRAW_GID     group of the created node (default 1000)
#   PASSKEY_HIDRAW_POLL    poll interval seconds (default 2)

set -u

match="${PASSKEY_HIDRAW_MATCH:-Virtual FIDO2}"
own_uid="${PASSKEY_HIDRAW_UID:-1000}"
own_gid="${PASSKEY_HIDRAW_GID:-1000}"
poll="${PASSKEY_HIDRAW_POLL:-2}"

log() { echo ".> hidraw-watch: $*"; }

# Opening the node is what the device cgroup gates; creating it is not.
# Probe as the target user so a stale/mismatched cgroup major (baked at
# container creation) surfaces as a loud, greppable event instead of a
# silent WebAuthn failure inside Gateway. Returns 0 if openable/unknown,
# 1 on a permission-type denial.
probe_open() {
	local node="$1" err
	command -v setpriv >/dev/null 2>&1 || return 0
	if err="$(setpriv --reuid="$own_uid" --regid="$own_gid" --init-groups -- \
		head -c0 "$node" 2>&1 >/dev/null)"; then
		return 0
	fi
	case "$err" in
	*"Permission denied"* | *"Operation not permitted"*) return 1 ;;
	*)
		log "note: open probe for ${node} inconclusive: ${err}"
		return 0
		;;
	esac
}

log "watching /sys/class/hidraw for '${match}' (poll ${poll}s)"

while true; do
	for dev in /sys/class/hidraw/hidraw*; do
		[ -r "${dev}/device/uevent" ] || continue
		grep -q -- "$match" "${dev}/device/uevent" 2>/dev/null || continue

		name="$(basename "$dev")"
		node="/dev/${name}"
		# sysfs "dev" is "major:minor" in decimal.
		majmin="$(cat "${dev}/dev" 2>/dev/null)" || continue
		major="${majmin%%:*}"
		minor="${majmin##*:}"
		want="$(printf '%x:%x' "$major" "$minor")"

		if [ -e "$node" ] && [ "$(stat -c '%t:%T' "$node" 2>/dev/null)" = "$want" ]; then
			continue
		fi

		rm -f "$node" 2>/dev/null
		if ! mknod "$node" c "$major" "$minor" 2>/dev/null; then
			log "WARNING: mknod ${node} (char ${major}:${minor}) failed"
			continue
		fi
		chown "${own_uid}:${own_gid}" "$node" 2>/dev/null || true
		chmod 0600 "$node" 2>/dev/null || true
		log "created ${node} (char ${major}:${minor})"

		if probe_open "$node"; then
			log "openable as ${own_uid}:${own_gid}"
		else
			log "ALERT_PASSKEY_DEVICE_BLOCKED major=${major} minor=${minor} " \
				"node=${node} required_rule=\"c ${major}:* rwm\" " \
				"remediation=\"run deploy.sh to refresh HIDRAW_MAJOR in .env, then recreate the Gateway container\""
		fi
	done

	# Reap nodes whose backing hidraw device has gone (passless stopped or
	# restarted onto a new minor). Never touches unrelated devices.
	for node in /dev/hidraw*; do
		[ -e "$node" ] || continue
		name="$(basename "$node")"
		if [ ! -e "/sys/class/hidraw/${name}" ]; then
			rm -f "$node" 2>/dev/null && log "removed stale ${node}"
		fi
	done

	sleep "$poll"
done
