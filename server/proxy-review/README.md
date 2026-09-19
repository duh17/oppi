# Reverse-proxy and App Review harness

Isolated Docker proof for issue 39. Do not reuse `server/e2e/docker-compose.e2e.yml`.

- Project/container/network/volume prefix: `oppi-rp39-`
- Edge ports bind `127.0.0.1` only and never 7749, 7750, 17760, 8888, or 13001
- Origin backend is unpublished
- Writable state is named volumes; checkout binds are read-only fixtures
- No `docker.sock`, no home mounts, no global CA or `/etc/hosts` edits
- Model lane: `oppi-rp39-deterministic` (never oMLX, ds4, or mlx-serve)

```bash
cd server
env -u NO_COLOR -u FORCE_COLOR GIT_CONFIG_GLOBAL=/dev/null npm run test:proxy-review
```

Positive TLS clients must use `curl --cacert` / Node `ca` + `servername`. `curl -k` and `rejectUnauthorized: false` are not success proof.

The mint sidecar shares the origin data volume and may use the owner socket on loopback. `run-mint-sidecar.mjs` loads the TypeScript mint server from the built image; revoke clears the outstanding pairing token without minting a replacement. Bind is loopback unless `REVIEW_MINT_ALLOW_NON_LOOPBACK=1`. Reuse requires that cached pairing token to still be the persisted outstanding token. The Oppi public proxy must not forward `/r/<secret>` or Unix-socket paths.

Packaged review recipe: `docker-compose.review.yml`, `Caddyfile.review` (Oppi HTTPS only), and `Caddyfile.review-mint` (loopback mint ingress). Origin seeds a synthetic workspace named `review` and skips `oppi init` when `/data/oppi/config.json` already exists so restarts preserve pairing. Reviewers open `https://review.rp39.test:<RP39_MINT_PORT>/r/<secret>` on the mint ingress; that site 404s every other path and never publishes Oppi `:7750` or the owner socket.
