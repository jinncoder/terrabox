#!/usr/bin/env -S bash -c "sudo docker run -p 443:443 -it --rm \$(docker build --progress plain -f \$0 . 2>&1 | tee /dev/stderr | tail -n 4 | grep -oP 'sha256:[0-9a-f]*')"

# syntax = docker/dockerfile:1.4.0
FROM nginx:stable-bookworm

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /root

RUN apt-get update && \
    apt-get -yq install openssh-server && \
    mkdir -p /etc/pki/nginx && \
    openssl req -nodes -x509 -sha256 -newkey rsa:2048 -keyout "/etc/pki/nginx/server.key" -out "/etc/pki/nginx/server.crt" -days 365 -subj "/C=??/ST=?/L=?/O=?/OU=?/CN=hype.tld" -addext "subjectAltName = DNS:hype.tld" && \
    openssl dhparam -out /etc/nginx/dhparam.pem 2048 && \
    mkdir -p /var/www/site && \
    useradd -m -s /bin/bash user && \
    echo "user:password" | chpasswd && \
    usermod -aG sudo user && \
    mkdir -p /run/sshd

RUN <<EOF cat >/var/www/site/index.html
<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Hype!</title>
        <style>
        body {
            margin: 0;
            font-family: sans-serif;
            background-color: #f0f0f0;
            color: #333;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
        }
        h1 {
            font-size: 2rem;
        }
        </style>
    </head>
    <body>
        <h1>Hello, World!</h1>
    </body>
</html>
EOF

RUN <<EOF cat >/etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
ListenAddress 127.0.0.1
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF

RUN <<EOF cat >/etc/nginx/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

stream {
    upstream ssh {
        server 127.0.0.1:22;
    }

    upstream web {
        server 127.0.0.1:8443;
    }

    map \$ssl_preread_protocol \$upstream {
        "" ssh;
        default web;
    }

    server {
        listen 443;
        proxy_pass \$upstream;
        ssl_preread on;
    }
}

http {
    log_format main '\$remote_addr - \$remote_user [$time_local] "\$request" '
                    '\$status $body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log                      /var/log/nginx/access.log  main;
    server_tokens                   off;

    sendfile                        on;
    tcp_nopush                      on;
    keepalive_timeout               65;
    types_hash_max_size             4096;

    include                         /etc/nginx/mime.types;
    default_type                    application/octet-stream;

    server {
        listen                      127.0.0.1:8443 ssl;
        http2                       on;
        server_name                 hype.tld;
        root                        /var/www/site;

        ssl_certificate             "/etc/pki/nginx/server.crt";
        ssl_certificate_key         "/etc/pki/nginx/server.key";

        ssl_dhparam                 "/etc/nginx/dhparam.pem";

        ssl_session_cache           shared:SSL:1m;
        ssl_session_timeout         10m;

        ssl_protocols               TLSv1.2 TLSv1.3;
        ssl_ciphers                 HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers   on;

        index                       index.php index.html;

        include                     /etc/nginx/default.d/*.conf;
    }

    include                         /etc/nginx/conf.d/*.conf;
}
EOF

RUN <<EOF cat >/entrypoint.sh
#!/usr/bin/bash

/usr/sbin/sshd -4 -p 22 -q &

nginx -g "daemon off;"
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 443

ENTRYPOINT ["/entrypoint.sh"]
