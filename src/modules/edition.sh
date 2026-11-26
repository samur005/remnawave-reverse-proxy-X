#!/bin/bash
# Official Remnawave images vs Remnawave X (qWDTT + branded subscription page).

REMN_EDITION_FILE="${DIR_REMNAWAVE}edition"
REMN_BACKEND_OFFICIAL="remnawave/backend:3"
REMN_NODE_OFFICIAL="remnawave/node:latest"
REMN_SUB_OFFICIAL="remnawave/subscription-page:latest"
REMN_BACKEND_X="ghcr.io/samur005/backend-x:3"
REMN_NODE_X="ghcr.io/samur005/node-x:latest"
REMN_SUB_X="ghcr.io/samur005/subscription-page-x:latest"

REMN_EDITION="${REMN_EDITION:-}"
REMN_BACKEND_IMAGE="${REMN_BACKEND_IMAGE:-$REMN_BACKEND_OFFICIAL}"
REMN_NODE_IMAGE="${REMN_NODE_IMAGE:-$REMN_NODE_OFFICIAL}"
REMN_SUB_IMAGE="${REMN_SUB_IMAGE:-$REMN_SUB_OFFICIAL}"

set_remn_edition_images() {
    local edition="${1:-official}"
    REMN_EDITION="$edition"
    if [ "$edition" = "custom" ]; then
        REMN_BACKEND_IMAGE="$REMN_BACKEND_X"
        REMN_NODE_IMAGE="$REMN_NODE_X"
        REMN_SUB_IMAGE="$REMN_SUB_X"
    else
        REMN_BACKEND_IMAGE="$REMN_BACKEND_OFFICIAL"
        REMN_NODE_IMAGE="$REMN_NODE_OFFICIAL"
        REMN_SUB_IMAGE="$REMN_SUB_OFFICIAL"
        REMN_EDITION="official"
    fi
}

detect_remn_edition() {
    local file
    for file in /opt/remnawave/docker-compose.yml /opt/remnanode/docker-compose.yml; do
        [ -f "$file" ] || continue
        if grep -qE 'image:[[:space:]]*ghcr.io/samur005/(backend-x|node-x|subscription-page-x)' "$file"; then
            echo custom
            return 0
        fi
        if grep -qE 'image:[[:space:]]*remnawave/(backend|node):' "$file"; then
            echo official
            return 0
        fi
    done
    return 1
}

load_remn_edition() {
    local edition=""
    if [ -f "$REMN_EDITION_FILE" ]; then
        edition=$(tr -d '[:space:]' < "$REMN_EDITION_FILE")
    fi
    if [ -z "$edition" ]; then
        edition=$(detect_remn_edition || true)
    fi
    [ -n "$edition" ] || edition="official"
    set_remn_edition_images "$edition"
}

save_remn_edition() {
    local edition="${1:-official}"
    mkdir -p "$(dirname "$REMN_EDITION_FILE")"
    printf '%s\n' "$edition" > "$REMN_EDITION_FILE"
    set_remn_edition_images "$edition"
}

# Ask Official vs Remnawave-X once, unless an edition is already saved or detected.
prompt_remn_edition() {
    local force="${1:-}"
    local choice=""
    load_remn_edition
    if [ "$force" != "force" ] && [ -f "$REMN_EDITION_FILE" ]; then
        return 0
    fi
    if [ "$force" != "force" ] && detect_remn_edition >/dev/null; then
        save_remn_edition "$(detect_remn_edition)"
        return 0
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[EDITION_TITLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[EDITION_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. ${LANG[EDITION_OFFICIAL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[EDITION_CUSTOM]}${COLOR_RESET}"
    reading "${LANG[EDITION_PROMPT]}" choice
    case "$choice" in
        2)
            save_remn_edition custom
            echo -e "${COLOR_GREEN}${LANG[EDITION_CUSTOM_SAVED]}${COLOR_RESET}"
            ;;
        *)
            save_remn_edition official
            echo -e "${COLOR_GREEN}${LANG[EDITION_OFFICIAL_SAVED]}${COLOR_RESET}"
            ;;
    esac
}

# Rewrite backend/node/subscription-page image lines to the saved edition.
rewrite_compose_images() {
    local file="$1"
    [ -f "$file" ] || return 0
    load_remn_edition
    local tmp
    tmp=$(mktemp)
    if [ "$REMN_EDITION" = "custom" ]; then
        sed -E \
            -e 's|(image:[[:space:]]*)remnawave/backend:[^[:space:]]+|\1'"$REMN_BACKEND_X"'|' \
            -e 's|(image:[[:space:]]*)ghcr.io/samur005/backend-x:[^[:space:]]+|\1'"$REMN_BACKEND_X"'|' \
            -e 's|(image:[[:space:]]*)remnawave/node:[^[:space:]]+|\1'"$REMN_NODE_X"'|' \
            -e 's|(image:[[:space:]]*)ghcr.io/samur005/node-x:[^[:space:]]+|\1'"$REMN_NODE_X"'|' \
            -e 's|(image:[[:space:]]*)remnawave/subscription-page:[^[:space:]]+|\1'"$REMN_SUB_X"'|' \
            -e 's|(image:[[:space:]]*)ghcr.io/samur005/subscription-page-x:[^[:space:]]+|\1'"$REMN_SUB_X"'|' \
            "$file" > "$tmp"
    else
        sed -E \
            -e 's|(image:[[:space:]]*)ghcr.io/samur005/backend-x:[^[:space:]]+|\1'"$REMN_BACKEND_OFFICIAL"'|' \
            -e 's|(image:[[:space:]]*)remnawave/backend:[^[:space:]]+|\1'"$REMN_BACKEND_OFFICIAL"'|' \
            -e 's|(image:[[:space:]]*)ghcr.io/samur005/node-x:[^[:space:]]+|\1'"$REMN_NODE_OFFICIAL"'|' \
            -e 's|(image:[[:space:]]*)remnawave/node:[^[:space:]]+|\1'"$REMN_NODE_OFFICIAL"'|' \
            -e 's|(image:[[:space:]]*)ghcr.io/samur005/subscription-page-x:[^[:space:]]+|\1'"$REMN_SUB_OFFICIAL"'|' \
            -e 's|(image:[[:space:]]*)remnawave/subscription-page:[^[:space:]]+|\1'"$REMN_SUB_OFFICIAL"'|' \
            "$file" > "$tmp"
    fi
    mv "$tmp" "$file"
}

backup_stack_dir() {
    local dir="$1"
    local ts backup_dir
    ts=$(date +%Y%m%d-%H%M%S)
    backup_dir="$dir/backup/update-$ts"
    if ! (umask 077 && mkdir -p "$backup_dir") || ! chmod 700 "$backup_dir"; then
        return 1
    fi
    [ -f "$dir/docker-compose.yml" ] && cp -a "$dir/docker-compose.yml" "$backup_dir/"
    [ -f "$dir/.env" ] && cp -a "$dir/.env" "$backup_dir/"
    [ -f "$dir/nginx.conf" ] && cp -a "$dir/nginx.conf" "$backup_dir/"
    [ -f "$dir/Caddyfile" ] && cp -a "$dir/Caddyfile" "$backup_dir/"
    (cd "$dir" && docker compose images > "$backup_dir/images-before.txt" 2>&1) || true
    printf '%s\n' "$backup_dir"
}

rollback_stack_dir() {
    local dir="$1"
    local backup_dir="$2"
    [ -d "$backup_dir" ] || return 1
    echo -e "${COLOR_YELLOW}${LANG[ROLLBACK_START]} ($dir)${COLOR_RESET}"
    cd "$dir" || return 1
    docker compose down > "$backup_dir/rollback-down.log" 2>&1 || true
    [ -f "$backup_dir/docker-compose.yml" ] && cp -a "$backup_dir/docker-compose.yml" "$dir/"
    [ -f "$backup_dir/.env" ] && cp -a "$backup_dir/.env" "$dir/"
    [ -f "$backup_dir/nginx.conf" ] && cp -a "$backup_dir/nginx.conf" "$dir/"
    [ -f "$backup_dir/Caddyfile" ] && cp -a "$backup_dir/Caddyfile" "$dir/"
    if docker compose up -d > "$backup_dir/rollback-up.log" 2>&1; then
        printf "${COLOR_GREEN}${LANG[ROLLBACK_DONE]}${COLOR_RESET}\n" "$backup_dir"
        return 0
    fi
    printf "${COLOR_RED}${LANG[ROLLBACK_FAILED]}${COLOR_RESET}\n" "$backup_dir"
    tail -n 20 "$backup_dir/rollback-up.log"
    return 1
}

latest_update_backup() {
    local dir="$1"
    ls -1dt "$dir"/backup/update-* 2>/dev/null | head -n 1
}
