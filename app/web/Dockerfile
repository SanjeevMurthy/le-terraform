# syntax=docker/dockerfile:1

# nginx-unprivileged is the plain nginx image rebuilt to run as UID 101 and
# listen on 8080. The stock nginx image runs as root and writes to
# /var/run/nginx.pid, so it fails under runAsNonRoot + readOnlyRootFilesystem.
# Starting from the unprivileged variant avoids a pile of workarounds.
FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html app.js styles.css /usr/share/nginx/html/

EXPOSE 8080
