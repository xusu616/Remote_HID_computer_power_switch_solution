# Sourced by CGI endpoints inside www/cgi-bin/
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

check_auth() {
    if [ "${TAILSCALE_ONLY:-0}" = "1" ]; then
        case "$REMOTE_ADDR" in
            100.*|127.0.0.1|::ffff:100.*|::ffff:127.0.0.1) ;;
            *)
                $BB printf "Status: 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nForbidden IP: %s\n" "$REMOTE_ADDR"
                exit 0
                ;;
        esac
    else
        case "$REMOTE_ADDR" in
            100.*|127.0.0.1|192.168.*|10.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2*|172.30.*|172.31.*|::ffff:100.*|::ffff:127.0.0.1|::ffff:192.168.*|::ffff:10.*) ;;
            *)
                $BB printf "Status: 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nForbidden IP: %s\n" "$REMOTE_ADDR"
                exit 0
                ;;
        esac
    fi

    REQ_TOKEN=""
    OLD_IFS="$IFS"
    IFS="&"
    for kv in $QUERY_STRING; do
        case "$kv" in
            token=*)
                REQ_TOKEN="${kv#token=}"
                break
                ;;
        esac
    done
    IFS="$OLD_IFS"

    if [ -z "$TOKEN" ] || [ "$REQ_TOKEN" != "$TOKEN" ]; then
        $BB printf "Status: 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nInvalid or missing token\n"
        exit 0
    fi
}
