#!/bin/bash
# Remnawave X only: after the panel is up, finish a turnkey setup
# from managed inbounds to hosts and qWDTT. Idempotent: never delete
# objects or duplicate inbounds/hosts that already exist.
#
# VK session cookies (remixsid) are never invented or submitted here.
# autoVkHash is only enabled as a panel option. The installer does not
# generate VK hashes and does not require cookies during install.
# Cookie values are never logged.

RWX_MANAGED_PROTOS="vless trojan shadowsocks hysteria"
RWX_QWDTT_PORT=56000
RWX_RESERVED_PORTS="22 80 443 56000 56001 56003"

rwx_msg() {
    local key="$1"
    shift || true
    local fmt="${LANG[$key]:-}"
    if [ -z "$fmt" ]; then
        case "$key" in
            RWX_PROVISION_START) fmt="Remnawave X: finishing turnkey setup (inbounds, squad, hosts, qWDTT)..." ;;
            RWX_PROVISION_OK) fmt="Remnawave X turnkey setup is in place" ;;
            RWX_PROVISION_SKIP) fmt="Remnawave X turnkey setup skipped (Official edition or no node)" ;;
            RWX_PROVISION_FAIL) fmt="Remnawave X turnkey setup could not finish: %s (the panel itself is up)" ;;
            RWX_PROVISION_PRIVATE) fmt="Public node address %s is private — hosts were not created with that address" ;;
            RWX_INBOUNDS_OK) fmt="Managed inbounds are present in the config profile" ;;
            RWX_NODE_BIND_OK) fmt="Managed inbounds are bound to node %s" ;;
            RWX_SQUAD_OK) fmt="Default squad includes the managed inbounds and qWDTT" ;;
            RWX_HOSTS_OK) fmt="Subscription hosts are in place for this node" ;;
            RWX_QWDTT_OK) fmt="qWDTT sidecar is assigned to this node; autoVkHash is enabled in the panel" ;;
            RWX_UFW_INBOUNDS_OK) fmt="Managed inbound ports opened in ufw: %s" ;;
            *) fmt="$key" ;;
        esac
    fi
    if [ "$#" -gt 0 ]; then
        # shellcheck disable=SC2059
        printf "$fmt" "$@"
    else
        printf '%s' "$fmt"
    fi
}

rwx_is_remnawave_x_edition() {
    if [ -z "${REMN_EDITION:-}" ] && type load_remn_edition >/dev/null 2>&1; then
        load_remn_edition
    fi
    [ "${REMN_EDITION:-}" = "custom" ]
}

rwx_is_ipv4() {
    [[ "${1:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

rwx_is_private_address() {
    local a="${1:-}"
    # Strip brackets from [::1] but keep host:port only when the host is IPv4.
    a="${a##*[}"
    a="${a%%]*}"
    local al
    al=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
    [ -z "$al" ] && return 0
    [ "$al" = "localhost" ] && return 0
    # host:port where host is IPv4 (do not treat the colon as IPv6)
    if [[ "$al" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$ ]]; then
        al="${al%%:*}"
    fi
    [ "$al" = "::1" ] && return 0
    if rwx_is_ipv4 "$al"; then
        [[ "$al" =~ ^127\. ]] && return 0
        [[ "$al" =~ ^10\. ]] && return 0
        [[ "$al" =~ ^192\.168\. ]] && return 0
        [[ "$al" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
        [[ "$al" =~ ^0\. ]] && return 0
        return 1
    fi
    # IPv6 (has colons): loopback, ULA, link-local. Hostnames are public.
    if [[ "$al" == *:* ]]; then
        local host="${al%%,*}"
        host="${host%%/*}"
        [ "$host" = "::1" ] && return 0
        [[ "$host" =~ ^fe80: ]] && return 0
        [[ "$host" =~ ^f[cd] ]] && return 0
        return 1
    fi
    return 1
}

rwx_is_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

rwx_api() {
    local method="$1" path="$2" body="${3:-}"
    make_api_request "$method" "http://${RWX_API_HOST}${path}" "$RWX_API_TOKEN" "$body"
}

rwx_sshd_ports() {
    local ports="" f
    if [ -f /etc/ssh/sshd_config ]; then
        ports=$(awk 'tolower($1)=="port" {print $2}' /etc/ssh/sshd_config 2>/dev/null)
    fi
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            ports="$ports $(awk 'tolower($1)=="port" {print $2}' "$f" 2>/dev/null)"
        done
    fi
    printf '%s\n' $ports $RWX_RESERVED_PORTS
}

rwx_port_taken() {
    local port="$1"
    local taken="$2"
    printf '%s\n' $taken | grep -qx "$port"
}

# Pick an unused port, starting at $start, skipping reserved + already used.
rwx_pick_port() {
    local start="$1"
    local taken="$2"
    local p="$start" i
    for i in $(seq 0 200); do
        p=$((start + i))
        if [ "$p" -gt 65535 ]; then
            break
        fi
        if rwx_port_taken "$p" "$taken"; then
            continue
        fi
        echo "$p"
        return 0
    done
    for p in $(seq 10001 10100); do
        if rwx_port_taken "$p" "$taken"; then
            continue
        fi
        echo "$p"
        return 0
    done
    return 1
}

rwx_ufw_allow_port() {
    local port="$1" proto="$2" comment="$3"
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow "${port}/${proto}" comment "$comment" >/dev/null 2>&1 || true
}

# Self-signed TLS material for Hysteria (Xray requires TLS). Printed as
# JSON {certificate,key} arrays of PEM lines — never logged.
rwx_selfsigned_tls_json() {
    local domain="$1"
    local dir cert key json
    dir=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap 'rm -rf "$dir"' RETURN
    cert="$dir/cert.pem"
    key="$dir/key.pem"
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
        -keyout "$key" -out "$cert" \
        -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1; then
        rm -rf "$dir"
        trap - RETURN
        return 1
    fi
    json=$(jq -n --rawfile cert "$cert" --rawfile key "$key" '{
        certificate: ($cert | rtrimstr("\n") | split("\n")),
        key: ($key | rtrimstr("\n") | split("\n"))
    }')
    rm -rf "$dir"
    trap - RETURN
    printf '%s' "$json"
}

rwx_find_node() {
    local nodes_json="$1"
    local want_uuid="${2:-}"
    local jq_prog
    jq_prog='
        def items:
            if type=="array" then .
            elif .response|type=="array" then .response
            else (.response.nodes // .nodes // []) end;
        items
    '
    if rwx_is_uuid "$want_uuid"; then
        echo "$nodes_json" | jq -c --arg u "$want_uuid" "$jq_prog | map(select(.uuid==\$u)) | first // empty"
        return
    fi
    echo "$nodes_json" | jq -c "$jq_prog |
        (map(select(.name==\"Steal\")) | first)
        // (if length==1 then .[0] else empty end)
        // first
        // empty"
}

rwx_profile_has_proto() {
    local config_json="$1" proto="$2"
    echo "$config_json" | jq -e --arg p "$proto" '
        [.inbounds[]? | .protocol] | index($p)
    ' >/dev/null 2>&1
}

# Build the three extra inbounds if a protocol is missing. $taken_ports is
# a whitespace list. Prints the new inbounds as a JSON array (possibly empty).
rwx_build_missing_inbounds() {
    local config_json="$1"
    local public_host="$2"
    local taken="$3"
    local missing_json="[]"
    local port tls cert_json

    if ! rwx_profile_has_proto "$config_json" "trojan"; then
        port=$(rwx_pick_port 8443 "$taken") || return 1
        taken="$taken $port"
        missing_json=$(jq -c --argjson acc "$missing_json" --argjson port "$port" '
            $acc + [{
                tag: "RWX_trojan",
                port: $port,
                protocol: "trojan",
                settings: { clients: [] },
                sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
            }]
        ')
    fi
    if ! rwx_profile_has_proto "$config_json" "shadowsocks"; then
        port=$(rwx_pick_port 8388 "$taken") || return 1
        taken="$taken $port"
        missing_json=$(jq -c --argjson acc "$missing_json" --argjson port "$port" '
            $acc + [{
                tag: "RWX_shadowsocks",
                port: $port,
                protocol: "shadowsocks",
                settings: { method: "chacha20-ietf-poly1305", clients: [], network: "tcp,udp" },
                sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
            }]
        ')
    fi
    if ! rwx_profile_has_proto "$config_json" "hysteria"; then
        port=$(rwx_pick_port 8447 "$taken") || return 1
        taken="$taken $port"
        cert_json=$(rwx_selfsigned_tls_json "$public_host") || return 1
        missing_json=$(jq -c --argjson acc "$missing_json" --argjson port "$port" --argjson tls "$cert_json" '
            $acc + [{
                tag: "RWX_hysteria2",
                port: $port,
                protocol: "hysteria",
                settings: { clients: [], version: 2 },
                sniffing: { enabled: true, destOverride: ["http","tls","quic"] },
                streamSettings: {
                    network: "hysteria",
                    security: "tls",
                    tlsSettings: { certificates: [ $tls ] }
                }
            }]
        ')
    fi
    printf '%s' "$missing_json"
    # Also print the final taken ports for the caller via a global.
    RWX_TAKEN_PORTS="$taken"
}

rwx_inbound_uuids_by_proto() {
    local inbounds_json="$1"
    # Prefer entity inbounds (uuid + type/protocol). Fall back to raw.
    echo "$inbounds_json" | jq -c '
        def proto: (.type // .protocol // "");
        [ .[]? | select(proto=="vless" or proto=="trojan" or proto=="shadowsocks" or proto=="hysteria")
          | {uuid, tag, protocol: proto, port} ]
    '
}

rwx_host_exists_for_inbound() {
    local hosts_json="$1" inbound_uuid="$2" node_uuid="$3"
    echo "$hosts_json" | jq -e --arg ib "$inbound_uuid" --arg n "$node_uuid" '
        def items:
            if type=="array" then .
            elif .response|type=="array" then .response
            else (.response.hosts // .hosts // []) end;
        items | map(select(
            (.isQwdtt|not)
            and ((.inbound.configProfileInboundUuid // "") == $ib)
            and (
                (($n|length)==0)
                or ((.nodes // [])|length==0)
                or ((.nodes // []) | map(if type=="object" then .uuid else . end) | index($n))
            )
        )) | length > 0
    ' >/dev/null 2>&1
}

rwx_qwdtt_host_exists() {
    local hosts_json="$1" node_uuid="$2"
    echo "$hosts_json" | jq -e --arg n "$node_uuid" '
        def items:
            if type=="array" then .
            elif .response|type=="array" then .response
            else (.response.hosts // .hosts // []) end;
        def nodeid: if type=="object" then .uuid else . end;
        items | map(select((.isQwdtt==true) and (
            ($n|length)==0 or ((.nodes // []) | map(nodeid) | index($n))
        ))) | length > 0
    ' >/dev/null 2>&1
}

# Main entry. Returns 0 even on skip; non-zero only for unexpected errors
# the caller may choose to ignore so the rest of the install can finish.
provision_remnawave_x_turnkey() {
    local domain_url="$1"
    local token="$2"
    local public_host="$3"
    local node_uuid="${4:-${CREATED_NODE_UUID:-}}"

    if ! rwx_is_remnawave_x_edition; then
        return 0
    fi
    if [ -z "$domain_url" ] || [ -z "$token" ]; then
        return 0
    fi

    RWX_API_HOST="$domain_url"
    RWX_API_TOKEN="$token"

    step_do "$(rwx_msg RWX_PROVISION_START)" 2>/dev/null || echo "$(rwx_msg RWX_PROVISION_START)"

    if ! provision_remnawave_x_turnkey_body "$public_host" "$node_uuid"; then
        local reason="${RWX_LAST_ERROR:-unknown error}"
        echo -e "${COLOR_YELLOW}$(rwx_msg RWX_PROVISION_FAIL "$reason")${COLOR_RESET}"
        return 1
    fi
    step_ok "$(rwx_msg RWX_PROVISION_OK)" 2>/dev/null || echo -e "${COLOR_GREEN}$(rwx_msg RWX_PROVISION_OK)${COLOR_RESET}"
    return 0
}

provision_remnawave_x_turnkey_body() {
    local public_host="$1"
    local node_uuid="$2"
    RWX_LAST_ERROR=""

    local nodes_json node_json node_name profile_uuid
    nodes_json=$(rwx_api GET /api/nodes) || { RWX_LAST_ERROR="could not list nodes"; return 1; }
    node_json=$(rwx_find_node "$nodes_json" "$node_uuid")
    if [ -z "$node_json" ] || [ "$node_json" = "null" ]; then
        RWX_LAST_ERROR="no node to bind"
        return 1
    fi
    node_uuid=$(echo "$node_json" | jq -r '.uuid')
    node_name=$(echo "$node_json" | jq -r '.name // "Steal"')
    profile_uuid=$(echo "$node_json" | jq -r '.configProfile.activeConfigProfileUuid // empty')
    if ! rwx_is_uuid "$node_uuid" || ! rwx_is_uuid "$profile_uuid"; then
        RWX_LAST_ERROR="node has no config profile"
        return 1
    fi

    if ! rwx_is_private_address "$public_host"; then
        :
    else
        echo -e "${COLOR_YELLOW}$(rwx_msg RWX_PROVISION_PRIVATE "$public_host")${COLOR_RESET}"
        public_host=""
    fi

    local profiles_json config_json taken extra_json new_config
    profiles_json=$(rwx_api GET /api/config-profiles) || { RWX_LAST_ERROR="could not read config profiles"; return 1; }
    config_json=$(echo "$profiles_json" | jq -c --arg u "$profile_uuid" '
        (.response.configProfiles // .response // []) | map(select(.uuid==$u)) | first | .config // empty
    ')
    if [ -z "$config_json" ] || [ "$config_json" = "null" ]; then
        local one
        one=$(rwx_api GET "/api/config-profiles/$profile_uuid") || true
        config_json=$(echo "$one" | jq -c '.response.config // .config // empty')
    fi
    if [ -z "$config_json" ] || [ "$config_json" = "null" ]; then
        RWX_LAST_ERROR="config profile has no Xray config"
        return 1
    fi

    taken="$(rwx_sshd_ports) $(echo "$config_json" | jq -r '[.inbounds[]? | .port] | join(" ")')"
    RWX_TAKEN_PORTS="$taken"
    extra_json=$(rwx_build_missing_inbounds "$config_json" "${public_host:-localhost}" "$taken") || {
        RWX_LAST_ERROR="could not build managed inbounds"
        return 1
    }
    taken="${RWX_TAKEN_PORTS:-$taken}"

    if [ "$extra_json" != "[]" ]; then
        new_config=$(jq -c --argjson extra "$extra_json" '.inbounds += $extra' <<<"$config_json")
        local patch body resp
        body=$(jq -c --arg u "$profile_uuid" --argjson config "$new_config" '{uuid:$u, config:$config}')
        resp=$(rwx_api PATCH /api/config-profiles "$body")
        if ! echo "$resp" | jq -e '.response.uuid // .response.config' >/dev/null 2>&1; then
            RWX_LAST_ERROR="could not update the config profile"
            return 1
        fi
        config_json=$(echo "$resp" | jq -c '.response.config // empty')
        [ -n "$config_json" ] && [ "$config_json" != "null" ] || config_json="$new_config"
    fi
    step_ok "$(rwx_msg RWX_INBOUNDS_OK)" 2>/dev/null || true

    # Refresh entity inbounds (uuids) from the profile.
    profiles_json=$(rwx_api GET /api/config-profiles)
    local entity_inbounds managed
    entity_inbounds=$(echo "$profiles_json" | jq -c --arg u "$profile_uuid" '
        (.response.configProfiles // .response // []) | map(select(.uuid==$u)) | first | .inbounds // []
    ')
    managed=$(rwx_inbound_uuids_by_proto "$entity_inbounds")
    local managed_uuids
    managed_uuids=$(echo "$managed" | jq -c '[.[].uuid]')
    if [ "$(echo "$managed_uuids" | jq 'length')" -lt 1 ]; then
        RWX_LAST_ERROR="no managed inbounds on the profile"
        return 1
    fi

    local existing_active union_inbounds
    existing_active=$(echo "$node_json" | jq -c '[.configProfile.activeInbounds[]? | if type=="object" then .uuid else . end]')
    union_inbounds=$(jq -c --argjson a "$existing_active" --argjson b "$managed_uuids" '$a + $b | unique')
    local need_bind
    need_bind=$(jq -e --argjson a "$existing_active" --argjson b "$managed_uuids" '
        ($b - $a) | length > 0
    ' >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$need_bind" = "1" ]; then
        local nbody nresp
        nbody=$(jq -c --arg u "$node_uuid" --arg p "$profile_uuid" --argjson ib "$union_inbounds" \
            '{uuid:$u, configProfile:{activeConfigProfileUuid:$p, activeInbounds:$ib}}')
        nresp=$(rwx_api PATCH /api/nodes "$nbody")
        if ! echo "$nresp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            RWX_LAST_ERROR="could not bind inbounds to the node"
            return 1
        fi
    fi
    step_ok "$(rwx_msg RWX_NODE_BIND_OK "$node_name")" 2>/dev/null || true

    if ! rwx_ensure_squad "$managed_uuids"; then
        return 1
    fi
    step_ok "$(rwx_msg RWX_SQUAD_OK)" 2>/dev/null || true

    if [ -n "$public_host" ]; then
        if ! rwx_ensure_hosts "$public_host" "$profile_uuid" "$node_uuid" "$node_name" "$managed"; then
            return 1
        fi
        step_ok "$(rwx_msg RWX_HOSTS_OK)" 2>/dev/null || true
    fi

    if ! rwx_ensure_qwdtt "$public_host" "$node_uuid"; then
        return 1
    fi

    # Open chosen managed ports (and qWDTT, already opened elsewhere — safe to retry).
    if [ -n "$extra_json" ] && [ "$extra_json" != "[]" ]; then
        local p proto comment opened=""
        while IFS=$'\t' read -r proto p; do
            [ -n "$p" ] || continue
            comment="Remnawave X $proto"
            case "$proto" in
                hysteria)
                    rwx_ufw_allow_port "$p" udp "$comment"
                    ;;
                shadowsocks)
                    rwx_ufw_allow_port "$p" tcp "$comment"
                    rwx_ufw_allow_port "$p" udp "$comment"
                    ;;
                *)
                    rwx_ufw_allow_port "$p" tcp "$comment"
                    ;;
            esac
            opened="$opened $proto:$p"
        done < <(echo "$extra_json" | jq -r '.[] | [.protocol, (.port|tostring)] | @tsv')
        command -v ufw >/dev/null 2>&1 && ufw reload >/dev/null 2>&1 || true
        [ -n "$opened" ] && echo "$(rwx_msg RWX_UFW_INBOUNDS_OK "$opened")"
    fi

    return 0
}

rwx_ensure_squad() {
    local managed_uuids="$1"
    local squads_json
    squads_json=$(rwx_api GET /api/internal-squads) || { RWX_LAST_ERROR="could not list squads"; return 1; }

    local pick
    pick=$(echo "$squads_json" | jq -c --argjson need "$managed_uuids" '
        def items: .response.internalSquads // .response // [];
        def ibs: [(.inbounds // [])[] | if type=="object" then .uuid else . end];
        def isdef: ((.name // "") | ascii_downcase) as $n | ($n=="default" or $n=="remnawave x");
        (items | map(select(isdef)) | first)
        // (if (items|length)==1 then items[0] else empty end)
        // (items | map(select((ibs - $need | length)==0 and ($need|length)>0)) | first)
        // empty
    ')

    if [ -z "$pick" ] || [ "$pick" = "null" ]; then
        local body resp
        body=$(jq -c --argjson ib "$managed_uuids" '{name:"Remnawave X", inbounds:$ib, includeQwdtt:true}')
        resp=$(rwx_api POST /api/internal-squads "$body")
        if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            RWX_LAST_ERROR="could not create the default squad"
            return 1
        fi
        return 0
    fi

    local suuid existing merged include already
    suuid=$(echo "$pick" | jq -r '.uuid')
    existing=$(echo "$pick" | jq -c '[.inbounds[]? | if type=="object" then .uuid else . end]')
    merged=$(jq -c --argjson a "$existing" --argjson b "$managed_uuids" '$a + $b | unique')
    include=$(echo "$pick" | jq -r '.includeQwdtt // false')
    already=$(jq -e --argjson a "$existing" --argjson b "$managed_uuids" '($b-$a|length)==0' >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$already" = "1" ] && [ "$include" = "true" ]; then
        return 0
    fi
    local body resp
    body=$(jq -c --arg u "$suuid" --argjson ib "$merged" '{uuid:$u, inbounds:$ib, includeQwdtt:true}')
    resp=$(rwx_api PATCH /api/internal-squads "$body")
    if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
        RWX_LAST_ERROR="could not update the default squad"
        return 1
    fi
    return 0
}

rwx_ensure_hosts() {
    local public_host="$1" profile_uuid="$2" node_uuid="$3" node_name="$4" managed="$5"
    local hosts_json
    hosts_json=$(rwx_api GET /api/hosts) || { RWX_LAST_ERROR="could not list hosts"; return 1; }

    local item uuid proto port remark body resp sni fingerprint
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        uuid=$(echo "$item" | jq -r '.uuid')
        proto=$(echo "$item" | jq -r '.protocol')
        port=$(echo "$item" | jq -r '.port')
        if rwx_host_exists_for_inbound "$hosts_json" "$uuid" "$node_uuid"; then
            continue
        fi
        case "$proto" in
            vless) remark="$node_name · VLESS Reality" ;;
            trojan) remark="$node_name · Trojan" ;;
            shadowsocks) remark="$node_name · Shadowsocks" ;;
            hysteria) remark="$node_name · Hysteria2" ;;
            *) remark="$node_name · $proto" ;;
        esac
        sni="$public_host"
        fingerprint="firefox"
        if [ "$proto" = "shadowsocks" ]; then
            sni=""
            fingerprint=""
        fi
        body=$(jq -n \
            --arg cu "$profile_uuid" --arg iu "$uuid" \
            --arg remark "$remark" --arg address "$public_host" \
            --argjson port "$port" --arg sni "$sni" --arg fp "$fingerprint" \
            --arg node "$node_uuid" \
            '{
                inbound: {configProfileUuid:$cu, configProfileInboundUuid:$iu},
                remark:$remark,
                address:$address,
                port:$port,
                path:"",
                sni: (if $sni=="" then null else $sni end),
                host:"",
                alpn:null,
                fingerprint: (if $fp=="" then null else $fp end),
                isDisabled:false,
                securityLayer:"DEFAULT",
                nodes:[$node]
            }')
        resp=$(rwx_api POST /api/hosts "$body")
        if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            RWX_LAST_ERROR="could not create a $proto host"
            return 1
        fi
        hosts_json=$(echo "$hosts_json" | jq -c --argjson h "$(echo "$resp" | jq -c '.response')" '
            if type=="array" then . + [$h]
            elif .response|type=="array" then .response += [$h] | .
            else .
            end
        ')
    done < <(echo "$managed" | jq -c '.[]')

    if ! rwx_qwdtt_host_exists "$hosts_json" "$node_uuid"; then
        if rwx_is_private_address "$public_host"; then
            return 0
        fi
        body=$(jq -n \
            --arg remark "$node_name · qWDTT" \
            --arg address "$public_host" \
            --argjson port "$RWX_QWDTT_PORT" \
            --arg node "$node_uuid" \
            '{
                isQwdtt:true,
                remark:$remark,
                address:$address,
                port:$port,
                isDisabled:false,
                nodes:[$node]
            }')
        resp=$(rwx_api POST /api/hosts "$body")
        if ! echo "$resp" | jq -e '.response.uuid' >/dev/null 2>&1; then
            RWX_LAST_ERROR="could not create the qWDTT host"
            return 1
        fi
    fi
    return 0
}

rwx_ensure_qwdtt() {
    local public_host="$1" node_uuid="$2"
    local view
    view=$(rwx_api GET /api/qwdtt)
    if ! echo "$view" | jq -e '.response' >/dev/null 2>&1; then
        RWX_LAST_ERROR="could not read qWDTT settings"
        return 1
    fi

    local sub_now nodes_now enabled auto
    sub_now=$(echo "$view" | jq -r '.response.subHost // ""')
    nodes_now=$(echo "$view" | jq -c '.response.nodeUuids // []')
    enabled=$(echo "$view" | jq -r '.response.enabled // false')
    auto=$(echo "$view" | jq -r '.response.autoVkHash // false')

    local merged_nodes want_sub body resp need_patch=0
    merged_nodes=$(jq -c --argjson a "$nodes_now" --arg n "$node_uuid" '$a + [$n] | unique')
    want_sub="$sub_now"
    if [ -z "$sub_now" ] && [ -n "$public_host" ] && ! rwx_is_private_address "$public_host"; then
        want_sub="$public_host"
    fi
    if [ "$enabled" != "true" ] || [ "$auto" != "true" ]; then
        need_patch=1
    fi
    if ! jq -e --argjson a "$nodes_now" --arg n "$node_uuid" '$a|index($n)' >/dev/null 2>&1; then
        need_patch=1
    fi
    if [ "$want_sub" != "$sub_now" ]; then
        need_patch=1
    fi
    if [ "$need_patch" = "1" ]; then
        body=$(jq -n --argjson nodes "$merged_nodes" --arg sub "$want_sub" '{
            enabled:true,
            autoVkHash:true,
            nodeUuids:$nodes,
            syncNodes:true
        } + (if $sub=="" then {} else {subHost:$sub} end)')
        resp=$(rwx_api PATCH /api/qwdtt "$body")
        if ! echo "$resp" | jq -e '.response' >/dev/null 2>&1; then
            RWX_LAST_ERROR="could not update qWDTT settings"
            return 1
        fi
        view="$resp"
    fi
    step_ok "$(rwx_msg RWX_QWDTT_OK)" 2>/dev/null || true
    return 0
}

# Wrapper used by install_panel_node / add_node so a missing module or a
# provision error never aborts an otherwise successful install.
run_remnawave_x_turnkey() {
    local domain_url="$1" token="$2" public_host="$3" node_uuid="${4:-}"
    if ! type provision_remnawave_x_turnkey >/dev/null 2>&1; then
        if type load_provision_remnawave_x_module >/dev/null 2>&1; then
            load_provision_remnawave_x_module true || {
                echo -e "${COLOR_YELLOW}$(rwx_msg RWX_PROVISION_FAIL "module not loaded")${COLOR_RESET}"
                return 0
            }
        fi
    fi
    if ! type provision_remnawave_x_turnkey >/dev/null 2>&1; then
        return 0
    fi
    provision_remnawave_x_turnkey "$domain_url" "$token" "$public_host" "$node_uuid" || true
}
