# Networking

## Model

With `compose.throttle.yml`, devimage has fail-closed outbound networking:

- `devimage` is attached to an internal Docker network with no direct egress route.
- `HTTP_PROXY` and `HTTPS_PROXY` point at the throttle MITM proxy sidecar.
- Well-behaved HTTP(S) clients must use the proxy.
- Raw TCP, direct SSH, WebRTC, DNS-over-UDP, and clients that ignore proxy env usually fail.

Do not suggest bypassing the proxy. Either make the client honor proxy settings or explain that the protocol is intentionally blocked.

## TLS Trust

The MITM proxy signs upstream certificates. Trust is split by runtime:

- System tools (`curl`, `git`, `apt`, `pip`, Python requests) use the system CA store.
- Node CLIs use `NODE_EXTRA_CA_CERTS=/mnt/mitm-ca/mitmproxy-ca-cert.pem`.
- Node 24+ built-in `fetch` needs `NODE_USE_ENV_PROXY=1` to honor proxy env.
- Chrome uses an NSS profile DB under `/config/.pki/nssdb`.

The boot oneshot and manual command are:

```bash
devimage-trust-proxy-ca
```

Use Chrome ignore-cert flags only as a diagnostic or temporary workaround, not as the normal solution.

## Checks

```bash
env | rg '^(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|NODE_EXTRA_CA_CERTS|NODE_USE_ENV_PROXY)='
test -r /mnt/mitm-ca/mitmproxy-ca-cert.pem && echo mitm-ca-present
curl -v https://huggingface.co/ 2>&1 | rg 'CONNECT|issuer|SSL certificate|proxy'
```

If `curl` verifies but Chrome/Playwright fails with certificate errors, run `devimage-trust-proxy-ca` and check `/config/.pki/nssdb`.

If `git+ssh` fails, switch the remote to HTTPS or configure SSH over the HTTP proxy. Plain SSH egress is expected to fail under the throttle overlay.

## Ports

The throttle overlay publishes inbound access through an `ingress` sidecar:

- Selkies desktop: host `:8080` to devimage `:3000`.
- Ad-hoc dev servers: host `:18000-18009` to matching devimage ports.

Inside the container, prefer connecting directly to local services by container-local address, for example `http://127.0.0.1:18000`.
