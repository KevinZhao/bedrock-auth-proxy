# syntax=docker/dockerfile:1.7

FROM nginx:1.27-alpine

RUN apk add --no-cache gettext tini \
 && rm /etc/nginx/conf.d/default.conf

COPY nginx/nginx.conf                      /etc/nginx/nginx.conf
COPY nginx/conf.d/gateway.conf.template    /etc/nginx/templates/gateway.conf.template
COPY nginx/docker-entrypoint.sh            /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && mkdir -p /var/cache/nginx /var/run \
 && chown -R nginx:nginx /var/cache/nginx /var/run /etc/nginx

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
