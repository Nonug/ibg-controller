# Passless (headless passkey login)

How to complete IBKR's passkey / WebAuthn 2FA unattended, using the
[passless](https://github.com/pando85/passless) software authenticator as
a sidecar next to the `ibg-controller` Gateway container.

`ibg-controller` itself only **presses Authenticate** on Gateway's passkey
prompt (`PASSKEY_AUTHENTICATE=yes`) — it never holds or emulates a passkey.
The ceremony is completed by an authenticator running alongside the
container. This page covers the virtual-FIDO2 arrangement, which is the one
that needs container-side plumbing (a device bridge). A hardware key passed
through, or a person on VNC, needs none of the below and is out of scope
here.

> **Security first.** The passless credential is a *software* secret and
> user-verification (UV) is auto-approved by passless itself
> (`PASSLESS_INTERACTION_MODE=automatic`). That is equivalent to leaving a
> hardware key plugged in and permanently touched: anything that can drive
> the authenticator and read the pass store can assert. Treat the sidecar's
> pass store + GPG key as the security boundary. See
> [Security model](#10-security-model).

## 1. How it works

```
┌─────────────────────────── ib-gateway container ───────────────────────────┐
│  IB Gateway (JVM)                                                          │
│    └─ JxBrowser (embedded) ── WebAuthn ── opens /dev/hidrawN               │
│                                                                            │
│  entrypoint.sh (root)                                                      │
│    └─ hidraw-watch.sh  → mknod /dev/hidrawN from sysfs (no udev in ctr)    │
│    └─ setpriv → run.sh + gateway_controller.py as uid 1000                 │
└────────────────────────────────────────────────────────────────────────────┘
                                   │  shared host kernel
                                   ▼
┌──────────────────────────── passless container ────────────────────────────┐
│  passless        opens /dev/uhid → kernel creates /dev/hidrawN             │
│    │             credentials in a GPG-encrypted `pass` store, decrypted    │
│    │             with a passphrase-less key copy (no pinentry in the ctr)  │
│    └─ PASSLESS_INTERACTION_MODE=automatic approves WebAuthn UV natively    │
└────────────────────────────────────────────────────────────────────────────┘
```

Key facts (verified against a live IBKR passkey account, and end-to-end
on the pinned 10.50.1e base):

- Passless creates a virtual HID device via `/dev/uhid`; the kernel then
  creates a `/dev/hidrawN` node. Containers do not run udev, so the node must
  be created *inside* the Gateway container by `scripts/hidraw-watch.sh`.
- The Gateway runs its WebAuthn ceremony inside the embedded JxBrowser, so it
  discovers the authenticator through the shared host kernel.
- **IBKR requires UV** (`getAssertion` with `uv=true`) and sends an explicit
  `allowCredentials` list. A real passkey enrolled with IBKR is therefore
  required; a fabricated credential is rejected.
- **UV is made unattended by configuration, not a debug build.**
  `PASSLESS_E2E_AUTO_ACCEPT_UV` is compiled out of release builds
  (`#[cfg(debug_assertions)]`). Use `PASSLESS_INTERACTION_MODE=automatic`
  (0.20.0+), which approves WebAuthn UP/UV prompts natively.
- **The sidecar decrypts with a passphrase-less key copy** — the container
  has no pinentry/TTY (see §5.1).
- **amd64 only.** passless ships aarch64 binaries, but IBKR's arm64 installer
  ships no JxBrowser build, so the passkey flow cannot run on arm64 at all.

## 2. What this repository provides

| Path | Role |
|---|---|
| `scripts/entrypoint.sh` | Root init; optionally starts the watcher; drops to uid 1000 and execs `run.sh` |
| `scripts/hidraw-watch.sh` | `mknod`s the passless `/dev/hidrawN`, probes it as uid 1000, alerts if blocked |
| `Dockerfile` | `USER root` + `ENTRYPOINT` for the above (upstream ran as uid 1000 with no entrypoint) |

The **sidecar** image recipe is not in this repository yet — it currently
lives with the deployment compose project. Keeping it separate is deliberate:
passless is GPL-3.0 and `ibg-controller` is MIT, and the authenticator +
secrets must not end up in the Gateway image.

Env vars the bridge reads (see [OBSERVABILITY.md](OBSERVABILITY.md#env-vars)):

| Var | Default | Meaning |
|---|---|---|
| `PASSKEY_HIDRAW_BRIDGE` | unset (`no`) | `yes` starts the watcher as root |
| `PASSKEY_HIDRAW_MATCH` | `Virtual FIDO2` | `uevent` substring identifying the authenticator |
| `PASSKEY_HIDRAW_UID` / `_GID` | `1000` / `1000` | Owner of the created node |
| `PASSKEY_HIDRAW_POLL` | `2` | Poll interval, seconds |

`PASSKEY_HIDRAW_BRIDGE` is **opt-in and harmless when unset**: the entrypoint
still drops to uid 1000 and runs `run.sh` exactly as before.

## 3. Host prerequisites

```sh
# 1. uhid kernel module (containers cannot load modules)
sudo modprobe uhid
echo uhid | sudo tee /etc/modules-load.d/fido.conf

# 2. Let containers reach /dev/uhid via the fido group
sudo groupadd fido 2>/dev/null || true
echo 'KERNEL=="uhid", GROUP="fido", MODE="0660"' | sudo tee /etc/udev/rules.d/90-passless.rules
sudo udevadm control --reload-rules && sudo udevadm trigger

# 3. Note the group id — you will need it for compose (FIDO_GID)
getent group fido
ls -l /dev/uhid          # expect crw-rw---- root:fido
```

Host tooling: Docker Engine + Compose v2, and a JDK 17-compatible `javac`
to build the agent jar.

## 4. Build the image

```sh
cd <repo>          # the ibg-controller checkout

PATH=/usr/lib/jvm/java-26-openjdk/bin:$PATH make    # any JDK >= 17

docker build -t ibg-controller:edge .
```

A bare `docker build` uses the `Dockerfile`'s digest-pinned stable base —
the same one the release workflow ships. To run on a newer Gateway line,
point `UPSTREAM_IMAGE` at any gnzsnz tag and derive `IB_GATEWAY_VERSION`
from that tag, so the two stay in lockstep without editing a version by
hand (the version is only the image label):

```sh
UPSTREAM=ghcr.io/gnzsnz/ib-gateway:latest   # or any pinned tag
docker build -t ibg-controller:edge \
  --build-arg UPSTREAM_IMAGE="$UPSTREAM" \
  --build-arg IB_GATEWAY_VERSION="${UPSTREAM##*:}" .
```

> **The embedded browser needs system libraries.** The passkey prompt
> opens Gateway's JxBrowser, which depends on `libnss3`, `libgbm1`,
> `libatk*`, `xdg-utils` and friends. They landed upstream in
> [gnzsnz/ib-gateway-docker#440](https://github.com/gnzsnz/ib-gateway-docker/pull/440)
> (2026-08-29) and the repository's pinned base includes them; only a
> base predating that PR needs them added. See README → 2FA.

Build the sidecar image from its own recipe (upstream passless release
binary + GPG) and tag it locally, e.g. `ibg-passless-sidecar:local`.

## 5. Enroll a passkey with IBKR (one-time, attended)

The sidecar must hold the passkey IBKR expects. You cannot fabricate it, and
the pass store is portable, so do this once with a browser that can see
passless, then reuse the store.

1. Start passless where a browser can reach it — the sidecar with the host
   browser plus the host hidraw node, or the sidecar's store on the host with
   the local `passless` binary.
2. In a browser, log in to IBKR Client Portal → Settings → User Settings →
   Security → Secure Login System, and **add a passkey**.
3. Complete the WebAuthn registration. The UV prompt is auto-approved when the
   sidecar handles it; if running passless manually on the host, approve it.
4. Verify the credential landed:

   ```sh
   docker compose -f ibg-docker-compose.yml -f ibg-docker-compose.passless.yml \
     exec passless passless client list
   ```

> Enrollment changes your IBKR account. Only do it deliberately; IBKR may cap
> the number of passkeys.

### 5.1 Enroll on the host, then import the store

The simplest path is to enroll with the host `passless` binary and a normal
browser, then hand the resulting store to the sidecar. Placeholders
(`<GPG_KEY_ID>`, `<CREDENTIAL_ID>`) stand in for real values;
`interactivebrokers.com.hk` is the RP the credential is bound to.

```sh
cd <project>       # the deployment project

# 0. Confirm the passkey is enrolled and note the GPG key id
passless client list
gpg --list-secret-keys --keyid-format=long   # find <GPG_KEY_ID>

# 1. Copy the encrypted pass store (includes the IBKR credential)
cp -a ~/.password-store/. ./passless-data/store/

# 2. Export the secret key + ownertrust from the host
gpg --export-secret-keys --armor <GPG_KEY_ID> > /tmp/passless-key.asc
gpg --export-ownertrust                        > /tmp/passless-otrust.txt

# 3. Import them into the container GNUPGHOME (host uid must match sidecar
#    uid 1000; deploy.sh chowns the dirs when run as root)
GNUPGHOME=./passless-data/gnupg gpg --import /tmp/passless-key.asc
GNUPGHOME=./passless-data/gnupg gpg --import-ownertrust /tmp/passless-otrust.txt
rm -f /tmp/passless-key.asc /tmp/passless-otrust.txt

# 3b. Remove the passphrase from the sidecar's key COPY (required).
#     The container has no pinentry/TTY, so a passphrase-protected key only
#     decrypts while a host gpg-agent happens to hold the passphrase in its
#     cache; once that expires it fails with
#     `gpg: decryption failed: No secret key` and IBKR asks for another key.
GNUPGHOME=./passless-data/gnupg gpg --edit-key <GPG_KEY_ID>
#   gpg> passwd
#     current passphrase: <your passphrase>
#     new passphrase:      <Enter>   (empty)
#     repeat:              <Enter>   (confirm the warning with y)
#   gpg> save

# 4. Verify the key decrypts with NO passphrase
GNUPGHOME=./passless-data/gnupg gpg --list-secret-keys <GPG_KEY_ID>
GNUPGHOME=./passless-data/gnupg gpg --batch --pinentry-mode loopback \
  --passphrase '' --decrypt \
  ./passless-data/store/fido2/interactivebrokers.com.hk/<CREDENTIAL_ID>.gpg \
  >/dev/null && echo decrypt-OK
```

Keeping the passphrase is possible by presetting it into the container's
gpg-agent (`allow-preset-passphrase` + a long `default-cache-ttl`, then
`gpg-preset-passphrase` at startup), but the passphrase must then be stored
where the container can read it — the same at-rest exposure as an
unprotected key, with more moving parts.

## 6. Compose wiring

The Gateway container needs four things the default compose lacks:

1. `PASSKEY_AUTHENTICATE=yes` so the controller presses **Authenticate**
   on the passkey prompt; without it the prompt fails loudly.
2. `PASSKEY_HIDRAW_BRIDGE=yes` so the entrypoint starts the watcher.
3. A device cgroup rule allowing the hidraw **major** — the value is
   per-boot and cannot be a static `devices:` mapping, because the minor
   changes on every passless restart.
4. The `fido` group id, and `/dev/uhid` on the **sidecar** (not the Gateway).

`deploy.sh` computes the per-boot hidraw major, writes it into `.env`, and
brings the stack up. Plain compose commands keep working afterwards because
`.env` is auto-loaded and the rule falls back to an inert default (`0`).

```sh
cd <project>

export PASSLESS_STORE_DIR=/path/to/password-store
export PASSLESS_GNUPGHOME=/path/to/.gnupg
export FIDO_GID=$(getent group fido | cut -d: -f3)

./deploy.sh
```

Manual equivalent:

```sh
HIDRAW_MAJOR=$(awk '$2=="hidraw"{print $1}' /proc/devices)
printf 'HIDRAW_MAJOR=%s\n' "$HIDRAW_MAJOR" >> .env
docker compose -f ibg-docker-compose.yml -f ibg-docker-compose.passless.yml up -d
```

## 7. Verify

```sh
# 1. Sidecar: passless up (and the authenticator running)
docker compose -f ibg-docker-compose.yml -f ibg-docker-compose.passless.yml logs passless \
  | grep -E 'Authenticator is running|PASSLESS_INTERACTION_MODE|Credentials in storage'

# 2. Gateway: watcher created the node, privileges dropped
docker logs <gateway-container> 2>&1 | grep -E 'hidraw-watch|openable'
# expect:
#   .> hidraw-watch: created /dev/hidraw7 (char 243:7)
#   .> hidraw-watch: openable as 1000:1000

# 3. End-to-end: trigger a login and watch the credential + approval path
docker compose ... logs -f passless \
  | grep -E 'Reading credential|User verification via notification|GPG decryption|CTAP response'
```

A successful (default `automatic`) ceremony shows:

```
passless::authenticator  Reading credential: id=<CREDENTIAL_ID>
passless::notification   PASSLESS_INTERACTION_MODE=automatic: auto-approving UserVerification ... (rp=interactivebrokers.com.hk)
passless::authenticator  User verification via notification: accepted
passless                     CTAP response: <n> bytes
```

There must be **no** `GPG decryption failed` line.

## 8. Operations

| Situation | Action |
|---|---|
| Regular container restart | nothing — Docker restarts in place, the major is unchanged within a boot |
| Host reboot, major unchanged | nothing (containers auto-start) |
| Host reboot / kernel update, major changed | `./deploy.sh` (or set `HIDRAW_MAJOR` in `.env`, then `up -d`) |
| `ALERT_PASSKEY_DEVICE_BLOCKED` in Gateway logs | `./deploy.sh`, then recreate the Gateway container |
| Any `docker compose ... up/down` | fine; uses `HIDRAW_MAJOR` from `.env` (default `0` = bridge inert) |

`HIDRAW_MAJOR` defaults to `0`, an inert char-device rule, so Compose always
parses and the Gateway always starts. With the default, the passkey device
simply cannot be opened and the watcher logs the alert above. This is why
`docker compose up` never needs a runtime-computed variable.

No host systemd unit or timer is required. The major only changes on reboot;
running `./deploy.sh` when the alert appears is sufficient.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `hidraw-watch: ALERT_PASSKEY_DEVICE_BLOCKED` | `HIDRAW_MAJOR` in `.env` is stale. Run `./deploy.sh`, then `up -d`. |
| `hidraw-watch: WARNING: mknod ... failed` | Missing `CAP_MKNOD` (Docker default has it) or `/sys` not visible. |
| Gateway reaches "Use your Passkey device" but nothing happens | No authenticator: check the sidecar is up and the node is openable. |
| `gpg: decryption failed: No secret key`; browser says "try a different security key" | The sidecar key is passphrase-protected and the container has no pinentry/TTY. Remove the passphrase from the sidecar key copy — §5.1 step 3b. |
| Controller logs `Passkey dialog already shows the WebAuthn ceremony in progress` | Benign: IBKR's page auto-started the ceremony before the controller looked, so there is nothing to click. The authenticator completes it. |
| `ALERT_2FA_FAILED reason="passkey Authenticate lookup failed"` | The passkey prompt was seen but no Authenticate button could be activated and the ceremony never started. Check the sidecar. |

## 10. Security model

- **UV is auto-approved.** `PASSLESS_INTERACTION_MODE=automatic` (0.20.0+)
  makes passless approve WebAuthn user-presence/verification prompts itself,
  logging each approval with the RP. No human, no PIN.
- **The sidecar key is passphrase-less.** The container has no pinentry/TTY,
  so the key copy under `passless-data/gnupg` carries no passphrase (§5.1
  step 3b) — reading that directory is enough to decrypt the store. Keep your
  protected key in `~/.gnupg` if you need one there.
- **The credential is software.** Anyone who can read the GPG key + pass store
  can assert without passless. Host-root compromise defeats the sidecar
  entirely; a hardware key with biometric UV would not be.
- **What the sidecar does protect against:** a malicious page/extension or
  process that can drive CTAP but not read the pass store can no longer obtain
  an assertion silently.
- **The passkey only gates login.** Once a session exists, it does not
  constrain what the session can do. Keep IBKR-side controls (restricted
  trading permissions, withdrawal limits) as the real backstop.
- **Optional human consent.** A Telegram/ntfy approval step can replace
  automatic approval, but it does not fix host compromise (the key is still
  software) and it adds an availability dependency — no bot/network, no login.
  It raises the bar for silent abuse, not for a compromised host. Not
  implemented here; auto-accept is the chosen trade-off.

## 11. Rollback

```sh
cd <project>
docker compose -f ibg-docker-compose.yml up -d     # no sidecar, no bridge
docker rm -f <passless-container> 2>/dev/null
sed -i '/^HIDRAW_MAJOR=/d' .env
```

The rebuilt Gateway image remains functional without the bridge: with
`PASSKEY_HIDRAW_BRIDGE` unset, `entrypoint.sh` simply drops to uid 1000 and
runs `run.sh` as before.
