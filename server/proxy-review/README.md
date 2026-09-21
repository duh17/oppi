# Isolated App Review reverse-proxy stack

Disposable Oppi origin plus Caddy edge for App Review. Pairing is `oppi pair` on the origin. There is no mint sidecar and no `/r/<secret>` enrollment URL.

Do not reuse `server/e2e/docker-compose.e2e.yml`.

- Project/container/network/volume prefix: `oppi-rp39-`
- Edge ports bind `127.0.0.1` only and never 7749, 7750, 17760, 8888, or 13001
- Origin backend is unpublished
- Writable state is named volumes; checkout binds are read-only fixtures
- No `docker.sock`, no home mounts, no global CA or `/etc/hosts` edits
- Model lane: `oppi-rp39-deterministic` (never oMLX, ds4, or mlx-serve)
- Four-way matrix modes set `proxy.trustedPeers` even for verified-HTTPS origins so pairing rate limits use overwritten XFF (not skip-verify); attacker and legitimate client both go through the same edge with CA+hostname

## Bring up

From `server/proxy-review/`, provide a built origin image, a loopback HTTPS edge port, and a certs directory with `edge.crt`, `edge.key`, and `ca.crt` for `oppi.rp39.test`:

```bash
export RP39_ORIGIN_IMAGE=oppi-rp39-origin:test
export RP39_EDGE_PORT=18443
export RP39_CERTS_DIR=/path/to/certs

docker compose -f docker-compose.review.yml up -d
```

Origin seeds a synthetic workspace named `review` and skips `oppi init` when `/data/oppi/config.json` already exists so restarts preserve pairing. `Caddyfile.review` terminates Oppi HTTPS only.

## Pair for App Review notes

```bash
docker compose -f docker-compose.review.yml exec origin oppi pair --json
```

Paste the `oppi://connect` URL into App Review notes. `oppi pair` remains the pairing primitive.

## Re-pair

If Review asks again, use Resolution Center: run `oppi pair` on origin and send the new `oppi://connect` URL. Do not add a stable enrollment link.

## Automated proof

Positive TLS clients must use `curl --cacert` / Node `ca` + `servername`. `curl -k` and `rejectUnauthorized: false` are not success proof.

```bash
cd server
env -u NO_COLOR -u FORCE_COLOR GIT_CONFIG_GLOBAL=/dev/null npm run test:proxy-review
```
