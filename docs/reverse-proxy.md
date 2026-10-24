# Reverse proxy

Run Oppi on a private listener and put an existing HTTPS domain in front of it. The phone uses the public origin and does not need to know whether you chose Caddy, nginx, or Cloudflare Tunnel.

## Configure Oppi

`host`, `port`, and `tls` describe the **listener**. `publicUrl` describes what the phone uses.

```bash
oppi config set host 127.0.0.1
oppi config set port 7750
oppi config set tls.mode disabled
oppi config set publicUrl https://oppi.example.com
oppi config set proxy.trustedPeers '["127.0.0.1/32","::1/128"]'
oppi config validate
oppi server restart
oppi pair
```

The signed invite advertises `https://oppi.example.com:443` and omits the origin TLS pin. The phone validates the public certificate with the system CA and still verifies Oppi's signed server identity.

Rules:

- `publicUrl` is HTTPS only. The port defaults to 443. Userinfo, query, fragment, and non-root paths are rejected, and a trailing `/` is dropped.
- `proxy.trustedPeers` are the **immediate socket peers as Oppi sees them**, usually the proxy's private IP or loopback, not the phone's IP or the public domain's IP. Set it for both private HTTP and verified-HTTPS origins. On a TLS origin it does not authorize plaintext and is not skip-verify; it only lets Oppi read a single overwritten `X-Forwarded-For` for pairing and challenge rate limits.
- `publicUrl` alone never authorizes plaintext credentials. Private HTTP needs a trusted peer **and** a single `X-Forwarded-Proto: https` value that the proxy overwrites.
- The proxy must overwrite `X-Forwarded-For`, not append to it. Append chains (ALB style) are not a trustworthy client identity, and Oppi falls back to the proxy's socket peer.
- Do not publish the backend port, and do not proxy the owner Unix socket. Owner `sk_` tokens and `/mirror/v1/bridge` stay local.
- `tls.mode=cloudflare` is not supported. Terminate TLS at the proxy.
- Do not disable upstream certificate verification (`noTLSVerify`, `tls_insecure_skip_verify`, or nginx `proxy_ssl_verify off`).

Direct self-signed LAN pairing stays available when `publicUrl` is unset. Same-user `/pair/tailscale` is unavailable whenever `publicUrl` is set. Without it, the endpoint rejects forwarding headers and the server's own Tailscale node, but a same-login, untagged node that forwards raw TCP without forwarding headers can still mint an invite, because these checks do not authenticate the caller behind that relay. Contributor notes: [Networking](../dev/networking.md).

## Caddy

Caddy issues the public certificate, upgrades WebSockets, and redirects HTTP to HTTPS so credential routes are never reachable in plaintext. Its default proxy behavior sets forwarded headers and ignores untrusted incoming values.

Same-host private HTTP origin, with the Oppi config above:

```caddyfile
oppi.example.com {
  reverse_proxy 127.0.0.1:7750
}
```

Verified-HTTPS origin: set Oppi to `tls.mode=self-signed` or `manual`, keep `proxy.trustedPeers`, and tell Caddy which CA and name to verify.

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

`header_up Host {hostport}` keeps the public Host distinct from the upstream TLS server name. `localhost` works only if it is in the backend certificate.

## nginx

Same-host private HTTP origin. The config needs the TLS server, HTTP-to-HTTPS redirect, upload limit, and WebSocket upgrade, and it overwrites forwarded headers.

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

Verified-HTTPS origin: keep the server, redirect, and WebSocket block and `proxy.trustedPeers`, and replace `proxy_pass` with the lines below. nginx defaults `proxy_ssl_verify` to `off`, so changing only `http://` to `https://` does **not** verify the backend.

```nginx
        proxy_pass https://127.0.0.1:7750;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /path/to/oppi/tls/self-signed/ca.crt;
        proxy_ssl_server_name on;
        proxy_ssl_name localhost;
```

## Cloudflare Tunnel

A dedicated `cloudflared` connector routes the public hostname to the private listener, so no inbound origin port is needed. Tunnel credentials and hostname routing are prerequisites. Set `proxy.trustedPeers` to the connector's actual local peer, often loopback; in separate containers, use the backend service address and the connector's network identity instead.

Private HTTP origin:

```yaml
ingress:
  - hostname: oppi.example.com
    service: http://127.0.0.1:7750
  - service: http_status:404
```

Verified-HTTPS origin:

```yaml
ingress:
  - hostname: oppi.example.com
    service: https://localhost:7750
    originRequest:
      caPool: /path/to/oppi/tls/self-signed/ca.crt
      originServerName: localhost
  - service: http_status:404
```

Oppi trusts the connector's socket peer, not Cloudflare headers a client sends. Enforce HTTPS at the public edge. Cloudflare Tunnel is not Cloudflare Access: a browser login or JavaScript challenge in front of Oppi's native API is not supported.
