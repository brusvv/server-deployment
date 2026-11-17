# Starter template only. Review/merge with MTProxyL-managed config before activation.
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 10s
    timeout client 300s
    timeout server 300s

frontend server_deployment_public
    bind :${PUBLIC_HTTPS_PORT}
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    use_backend mtproxyl_web_tls if { req.ssl_sni -i ${WEB_DOMAIN} }
    use_backend remnawave_xray if { req.ssl_sni -i ${PANEL_DOMAIN} ${SUBSCRIPTION_DOMAIN} ${SELFSTEAL_DOMAIN} }
    default_backend mtproxyl_mtproto

backend remnawave_xray
    mode tcp
    server xray ${XRAY_LOOPBACK_HOST}:${XRAY_LOOPBACK_PORT} check

backend mtproxyl_web_tls
    mode tcp
    server web ${WEB_TLS_HOST}:${WEB_TLS_PORT} check

backend mtproxyl_mtproto
    mode tcp
    server mtproto ${MTPROTO_BACKEND_HOST}:${MTPROTO_BACKEND_PORT} check
