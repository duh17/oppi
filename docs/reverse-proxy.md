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
- Set `proxy.trustedPeers` only for a **private HTTP** origin. For a verified-HTTPS origin, keep Oppi on `tls.mode=self-signed` or `manual` and omit HTTP-proxy trust.
- `publicUrl` alone never authorizes plaintext credentials. Private HTTP requires a trusted peer **and** a single `X-Forwarded-Proto: https` value that the proxy overwrites.
- The proxy must overwrite `X-Forwarded-For`. Oppi uses a single overwritten client IP for pairing/challenge rate limits. ALB-style append chains are not a trustworthy client identity; Oppi falls back to the proxy socket peer. Do not append untrusted incoming forwarded addresses.
- Do not publish the backend port. Do not proxy the owner Unix socket. Owner `sk_` tokens and `/mirror/v1/bridge` stay local.
- `tls.mode=cloudflare` is not a supported mode. Terminate TLS at the proxy and use `publicUrl` + `proxy.trustedPeers`.
- Do not disable upstream certificate verification (`noTLSVerify`, `tls_insecure_skip_verify`, or nginx `proxy_ssl_verify off`).

Direct self-signed LAN and Tailscale pairing stay unchanged when `publicUrl` is unset. Contributor notes: [Networking](../dev/networking.md).

## Caddy

Caddy issues the public certificate and upgrades WebSockets. Automatic HTTPS redirects HTTP to HTTPS so credential routes are not reachable in plaintext.

Same-host private HTTP origin (with the Oppi config above):

```caddyfile
oppi.example.com {
  reverse_proxy 127.0.0.1:7750
}
```

Caddy's default proxy behavior sets forwarded headers and ignores untrusted incoming values.

Verified-HTTPS origin: set Oppi to `tls.mode=self-signed` or `manual`, **omit** `proxy.trustedPeers`, and tell Caddy which CA and name to verify. Do not skip upstream TLS verification.

```caddyfile
oppi.example.com {
  reverse_proxy https://127.0.0.1:7750 {
    header_up Host {hostport}
    transport http {
      tls_trust_pool file /path/to/oppi/tls/self-signed/ca.crt
      tls_server_name localhost
    }
  }
}
```

`header_up Host {hostport}` keeps the public Host distinct from the upstream TLS server name. `localhost` is valid only if it is in the backend certificate.

## nginx

Same-host private HTTP origin. Include the TLS server, HTTP→HTTPS redirect, upload limit, and WebSocket upgrade. Overwrite forwarded headers; do not append client-supplied `X-Forwarded-For`.

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name oppi.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name oppi.example.com;
    ssl_certificate     /etc/letsencrypt/live/oppi.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/oppi.example.com/privkey.pem;
    client_max_body_size 80m;

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
}
```

Renew public certificates with your usual tooling (for example certbot). The snippet assumes nginx faces the client.

Verified-HTTPS origin: keep the server/redirect/WebSocket block, omit `proxy.trustedPeers`, replace `proxy_pass`, and enable verification. nginx defaults `proxy_ssl_verify` to `off`; changing only `http://` to `https://` does **not** verify the backend.

```nginx
        proxy_pass https://127.0.0.1:7750;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /path/to/oppi/tls/self-signed/ca.crt;
        proxy_ssl_server_name on;
        proxy_ssl_name localhost;
```

## Cloudflare Tunnel

A dedicated `cloudflared` connector routes the public hostname to the private listener. No public inbound origin port is needed. Tunnel identity/credentials and hostname routing are prerequisites.

Private HTTP origin (with `proxy.trustedPeers` set to the connector's actual local peer, often loopback):

```yaml
ingress:
  - hostname: oppi.example.com
    service: http://127.0.0.1:7750
  - service: http_status:404
```

Verified-HTTPS origin: omit HTTP-proxy trust and verify the backend CA and name.

```yaml
ingress:
  - hostname: oppi.example.com
    service: https://localhost:7750
    originRequest:
      caPool: /path/to/oppi/tls/self-signed/ca.crt
      originServerName: localhost
  - service: http_status:404
```

Oppi trusts the connector's socket peer, not arbitrary Cloudflare headers sent by a client. Enforce HTTPS at the public edge. Cloudflare Tunnel is not Cloudflare Access; a browser login/JavaScript challenge in front of Oppi's native API is not supported. In separate containers, use the backend service address and the connector's explicit network identity instead of loopback.
