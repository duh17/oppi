# Reverse proxy

Run Oppi on a private listener and put an existing HTTPS domain in front of it. The phone uses the public origin; it does not need to know whether you chose Caddy, nginx, or Cloudflare Tunnel.

## Configure Oppi

`host` / `port` / `tls` still describe the **listener**. `publicUrl` describes what the phone uses.

```bash
oppi config set host 127.0.0.1
oppi config set port 7750
oppi config set tls.mode disabled
oppi config set publicUrl https://oppi.example.com
oppi config set proxy.trustedPeers '["127.0.0.1/32","::1/128"]'
oppi config validate
```

Restart the server, then:

```bash
oppi pair
```

The signed invite advertises `https://oppi.example.com:443` and omits the origin TLS leaf pin. The phone validates the public certificate with the system CA and still verifies Oppi's signed server identity.

Rules:

- `publicUrl` is HTTPS only. Optional port defaults to 443. Userinfo, query, fragment, and non-root paths are rejected. A trailing `/` is normalized away.
- `proxy.trustedPeers` are the **immediate socket peers as Oppi sees them**, usually the proxy's private IP or loopback. They are not the phone IP or the public domain's IP.
- `publicUrl` alone never authorizes plaintext credentials. Private HTTP requires a trusted peer **and** a single `X-Forwarded-Proto: https` value that the proxy overwrites.
- Do not publish the backend port. Do not proxy the owner Unix socket. Owner `sk_` tokens and `/mirror/v1/bridge` stay local.
- `tls.mode=cloudflare` is not a supported mode. Terminate TLS at the proxy and use `publicUrl` + `proxy.trustedPeers`.

Same-host Caddy:

```caddyfile
oppi.example.com {
  reverse_proxy 127.0.0.1:7750
}
```

Same-host nginx (overwrite forwarded headers; enable WebSockets):

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

location / {
    proxy_pass http://127.0.0.1:7750;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
```

For a verified HTTPS upstream, keep Oppi on `tls.mode=self-signed` or `manual`, omit HTTP-proxy trust, and configure the proxy to verify the origin CA and hostname. Do not disable upstream certificate verification.

Direct self-signed LAN and Tailscale pairing stay unchanged when `publicUrl` is unset. Contributor notes: [Networking](../dev/networking.md).
