#!/usr/bin/env bash
set -eo pipefail

# Log color definitions
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}[START] Starting MesAR PKGBUILD version check...${NC}\n"

find . -maxdepth 2 -mindepth 2 -name "PKGBUILD" | while read -r pkgpath; do
  pkgdir=$(dirname "$pkgpath" | sed 's|^\./||')

  echo -e "${CYAN}--------------------------------------------------${NC}"
  
  # 1. Skip ONLY if directory ends with -git (VCS package)
  if [[ "$pkgdir" == *-git ]]; then
    echo -e "${YELLOW}[SKIPPED] ${pkgdir}${NC} -> VCS (-git) package, skipping check."
    continue
  fi

  echo -e "==> Checking: ${CYAN}${pkgdir}${NC}"

  cd "$pkgdir"

  # Read PKGBUILD variables safely
  current_pkgver=$(bash -c 'source PKGBUILD; echo "$pkgver"' 2>/dev/null || echo "")
  upstream_url=$(bash -c 'source PKGBUILD; echo "$url"' 2>/dev/null || echo "")
  
  # Extract any git repository link from PKGBUILD (source array or url)
  git_repo=$(bash -c 'source PKGBUILD; echo "${source[@]}" "$url"' 2>/dev/null | grep -oP 'https?://[^\s#]+\.git' | head -n 1 || true)

  if [ -z "$git_repo" ] && [ -n "$upstream_url" ]; then
    git_repo="$upstream_url"
  fi

  echo -e "  |-> Current PKGBUILD Version : ${YELLOW}${current_pkgver:-Unknown}${NC}"
  echo -e "  |-> Upstream URL             : ${upstream_url:-None}"

  latest_ver=""

  # Check if directory name targets pre-releases (e.g., eden-beta, app-rc, pkg-dev)
  if [[ "$pkgdir" =~ -(beta|rc|alpha|preview|dev)$ ]]; then
    echo -e "  |-> Mode                     : ${YELLOW}PRE-RELEASE ALLOWED${NC} (Suffix detected)"
    
    # 2A. Fetch latest tag including pre-releases
    if [ -n "$git_repo" ]; then
      latest_ver=$(git ls-remote --tags --refs "$git_repo" 2>/dev/null | \
        grep -oP 'refs/tags/v?\K[0-9]+(\.[0-9]+)+.*' | \
        sort -V | tail -n 1 || true)
    fi

    # Fallback to GitHub API (All releases including pre-releases)
    if [ -z "$latest_ver" ] && [[ "$upstream_url" == *"github.com"* ]]; then
      repo_path=$(echo "$upstream_url" | sed -e 's|https://github.com/||' -e 's|/$||')
      latest_ver=$(curl -s "https://api.github.com/repos/$repo_path/releases" | \
        grep -oP '"tag_name":\s*"v?\K[^"]+' | head -n 1 || true)
    fi

  else
    echo -e "  |-> Mode                     : ${GREEN}STABLE ONLY${NC} (Normal package)"
    
    # 2B. Fetch ONLY stable tags (Filter out rc, beta, alpha, dev, preview)
    if [ -n "$git_repo" ]; then
      latest_ver=$(git ls-remote --tags --refs "$git_repo" 2>/dev/null | \
        grep -oP 'refs/tags/v?\K[0-9]+(\.[0-9]+)+.*' | \
        grep -vE '(-|/)?(rc|alpha|beta|dev|preview|next|b[0-9]+|a[0-9]+)' | \
        sort -V | tail -n 1 || true)
    fi

    # Fallback to GitHub API (Latest stable release only)
    if [ -z "$latest_ver" ] && [[ "$upstream_url" == *"github.com"* ]]; then
      repo_path=$(echo "$upstream_url" | sed -e 's|https://github.com/||' -e 's|/$||')
      latest_ver=$(curl -s "https://api.github.com/repos/$repo_path/releases/latest" | \
        grep -oP '"tag_name":\s*"v?\K[^"]+' || true)
    fi
  fi

  # Convert hyphens to underscores for Arch Linux PKGBUILD compliance (e.g., 1.0.0-beta1 -> 1.0.0_beta1)
  if [ -n "$latest_ver" ]; then
    latest_ver=$(echo "$latest_ver" | tr '-' '_')
  fi

  echo -e "  |-> Detected Latest Version  : ${GREEN}${latest_ver:-Not Found}${NC}"

  # 3. Check for updates and apply changes
  if [ -n "$latest_ver" ] && [ "$latest_ver" != "$current_pkgver" ]; then
    echo -e "  ${GREEN}[+] NEW VERSION FOUND!${NC} Updating: ${YELLOW}${current_pkgver}${NC} -> ${GREEN}${latest_ver}${NC}"
    
    sed -i "s/^pkgver=.*/pkgver=$latest_ver/" PKGBUILD
    sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
    
    echo -e "  |-> Updating checksums (updpkgsums)..."
    if updpkgsums 2>&1 | sed 's/^/      /'; then
      echo -e "  ${GREEN}[OK] PKGBUILD and checksums updated successfully.${NC}"
    else
      echo -e "  ${RED}[ERROR] Failed to update checksums!${NC}"
    fi
  elif [ -z "$latest_ver" ]; then
    echo -e "  ${RED}[!] WARNING:${NC} Could not fetch upstream version."
  else
    echo -e "  ${GREEN}[OK] Package is already up to date.${NC}"
  fi

  cd ..
done

echo -e "\n${CYAN}--------------------------------------------------${NC}"
echo -e "${CYAN}[END] Version check completed.${NC}"
