#!/usr/bin/env bash

set -uo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ROOT_DIR=$PWD
DRY_RUN=${DRY_RUN:-0}

print_log() {
    printf '%b\n' "$*"
}

error_exit() {
    print_log "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

command -v bash >/dev/null 2>&1 ||
    error_exit "bash was not found."

command -v git >/dev/null 2>&1 ||
    error_exit "git was not found."

command -v curl >/dev/null 2>&1 ||
    error_exit "curl was not found."

command -v vercmp >/dev/null 2>&1 ||
    error_exit "vercmp was not found. Install the pacman-contrib package."

command -v updpkgsums >/dev/null 2>&1 ||
    error_exit "updpkgsums was not found. Install the pacman-contrib package."

read_pkgbuild_var() {
    local variable=$1

    bash -c "
        set +u
        source ./PKGBUILD >/dev/null 2>&1
        printf '%s' \"\${${variable}:-}\"
    " 2>/dev/null
}

get_git_repo() {
    local source_value
    local upstream_url
    local repo

    source_value=$(read_pkgbuild_var source)
    upstream_url=$(read_pkgbuild_var url)

    repo=$(
        {
            printf '%s\n' "$source_value"
            printf '%s\n' "$upstream_url"
        } |
            grep -oE '(https?|git)://[^[:space:]"]+\.git' |
            head -n 1
    )

    repo=${repo#git+}
    repo=${repo%%#*}

    printf '%s' "$repo"
}

get_github_repo() {
    local url=$1

    url=${url#https://github.com/}
    url=${url#http://github.com/}
    url=${url%%\?*}
    url=${url%%\#*}
    url=${url%.git}
    url=${url%/}

    if [[ "$url" =~ ^[^/]+/[^/]+$ ]]; then
        printf '%s' "$url"
    fi
}

get_git_version() {
    local repo=$1
    local include_prerelease=$2
    local tags

    tags=$(
        git ls-remote --tags --refs "$repo" 2>/dev/null |
            awk -F/ '
                {
                    tag = $3
                    sub(/^v/, "", tag)
                    print tag
                }
            ' |
            grep -E '^[0-9]+([.][0-9]+)+(.*)?$' ||
            true
    )

    if [[ "$include_prerelease" != "1" ]]; then
        tags=$(
            printf '%s\n' "$tags" |
                grep -Eiv \
                    '(^|[._-])(alpha|beta|rc|pre|preview|dev|devel|next|a[0-9]*|b[0-9]*)($|[._-]|[0-9])' ||
                true
        )
    fi

    if [[ -n "$tags" ]]; then
        printf '%s\n' "$tags" |
            sort -V |
            tail -n 1
    fi
}

get_github_version() {
    local repo=$1
    local include_prerelease=$2
    local api_url
    local response
    local version

    if [[ "$include_prerelease" == "1" ]]; then
        api_url="https://api.github.com/repos/${repo}/releases"
    else
        api_url="https://api.github.com/repos/${repo}/releases/latest"
    fi

    response=$(
        curl \
            --fail \
            --silent \
            --show-error \
            --connect-timeout 10 \
            --max-time 30 \
            -H 'Accept: application/vnd.github+json' \
            "$api_url" 2>/dev/null
    ) || return 0

    if command -v jq >/dev/null 2>&1; then
        if [[ "$include_prerelease" == "1" ]]; then
            version=$(
                jq -r '
                    .[]
                    | select(.draft == false)
                    | .tag_name
                ' <<< "$response" |
                    sed -E 's/^v//' |
                    grep -E '^[0-9]+([.][0-9]+)+(.*)?$' |
                    sort -V |
                    tail -n 1
            )
        else
            version=$(
                jq -r '.tag_name // empty' <<< "$response" |
                    sed -E 's/^v//'
            )
        fi
    else
        version=$(
            grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$response" |
                head -n 1 |
                sed -E 's/.*"([^"]+)".*/\1/' |
                sed -E 's/^v//'
        )
    fi

    printf '%s' "$version"
}

check_package() {
    local pkgdir=$1

    (
        cd "$ROOT_DIR/$pkgdir" || {
            print_log "${RED}[ERROR]${NC} Could not enter directory: $pkgdir"
            return 1
        }

        local current_pkgver
        local upstream_url
        local git_repo
        local latest_ver
        local github_repo
        local include_prerelease=0
        local backup_file

        print_log "${CYAN}--------------------------------------------------${NC}"
        print_log "==> Checking: ${CYAN}${pkgdir}${NC}"

        if [[ "$pkgdir" == *-git ]]; then
            print_log "${YELLOW}[SKIPPED]${NC} ${pkgdir} -> VCS package"
            return 0
        fi

        current_pkgver=$(read_pkgbuild_var pkgver)
        upstream_url=$(read_pkgbuild_var url)
        git_repo=$(get_git_repo || true)

        print_log "  |-> Current PKGBUILD version: ${YELLOW}${current_pkgver:-Unknown}${NC}"
        print_log "  |-> Upstream URL: ${upstream_url:-None}"

        if [[ "$pkgdir" =~ -(beta|rc|alpha|preview|dev)$ ]]; then
            include_prerelease=1
            print_log "  |-> Mode: ${YELLOW}PRERELEASES ALLOWED${NC}"
        else
            print_log "  |-> Mode: ${GREEN}STABLE RELEASES ONLY${NC}"
        fi

        latest_ver=""

        if [[ -n "$git_repo" ]]; then
            print_log "  |-> Git repository: $git_repo"

            latest_ver=$(
                get_git_version "$git_repo" "$include_prerelease" || true
            )
        fi

        if [[ -z "$latest_ver" && -n "$upstream_url" ]]; then
            github_repo=$(get_github_repo "$upstream_url" || true)

            if [[ -n "$github_repo" ]]; then
                print_log "  |-> Using GitHub API: $github_repo"

                latest_ver=$(
                    get_github_version "$github_repo" "$include_prerelease" || true
                )
            fi
        fi

        latest_ver=${latest_ver//-/_}

        print_log "  |-> Latest detected version: ${GREEN}${latest_ver:-Not Found}${NC}"

        if [[ -z "$latest_ver" ]]; then
            print_log "  ${RED}[WARNING]${NC} Could not fetch the upstream version."
            return 0
        fi

        if [[ -z "$current_pkgver" ]]; then
            print_log "  ${RED}[WARNING]${NC} Could not read the current pkgver."
            return 0
        fi

        if [[ "$latest_ver" == "$current_pkgver" ]]; then
            print_log "  ${GREEN}[OK]${NC} Package is already up to date."
            return 0
        fi

        if (( $(vercmp "$latest_ver" "$current_pkgver") <= 0 )); then
            print_log "  ${GREEN}[OK]${NC} No newer version was found."
            return 0
        fi

        print_log "  ${GREEN}[+] NEW VERSION FOUND${NC}"
        print_log "      ${YELLOW}${current_pkgver}${NC} -> ${GREEN}${latest_ver}${NC}"

        if [[ "$DRY_RUN" == "1" ]]; then
            print_log "  ${YELLOW}[DRY-RUN]${NC} No changes were made."
            return 0
        fi

        backup_file=$(mktemp)
        cp PKGBUILD "$backup_file"

        if grep -qE '^pkgver=' PKGBUILD; then
            sed -i -E "s/^pkgver=.*/pkgver=${latest_ver}/" PKGBUILD
        else
            print_log "  ${RED}[ERROR]${NC} pkgver was not found in PKGBUILD."
            rm -f "$backup_file"
            return 1
        fi

        if grep -qE '^pkgrel=' PKGBUILD; then
            sed -i -E 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
        else
            print_log "  ${YELLOW}[WARNING]${NC} pkgrel was not found. Adding it."
            sed -i '1i pkgrel=1' PKGBUILD
        fi

        print_log "  |-> Updating checksums..."

        if updpkgsums; then
            rm -f "$backup_file"
            print_log "  ${GREEN}[OK]${NC} PKGBUILD and checksums were updated."
        else
            cp "$backup_file" PKGBUILD
            rm -f "$backup_file"

            print_log "  ${RED}[ERROR]${NC} updpkgsums failed."
            print_log "  ${YELLOW}[ROLLBACK]${NC} PKGBUILD was restored."
        fi
    )
}

print_log "${CYAN}[START] Starting PKGBUILD version check...${NC}"
printf '\n'

while IFS= read -r -d '' pkgpath; do
    pkgdir=${pkgpath#./}
    pkgdir=${pkgdir%/PKGBUILD}

    check_package "$pkgdir"
done < <(
    find . \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name 'PKGBUILD' \
        -print0
)

printf '\n'
print_log "${CYAN}--------------------------------------------------${NC}"
print_log "${CYAN}[END] Version check completed.${NC}"
