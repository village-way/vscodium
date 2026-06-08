#!/usr/bin/env bash

APP_NAME="${APP_NAME:-Zhanlu}"
APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"
ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-village-way/zhanlu-code}" # zhanlu_change - default release assets belong to Zhanlu
BINARY_NAME="${BINARY_NAME:-zhanlu}"
COMPANY_NAME_EN="${COMPANY_NAME_EN:-China Mobile (Suzhou) Software Technology Co., Ltd.}" # zhanlu_change - keep Windows publisher display separate from technical org id
GH_REPO_PATH="${GH_REPO_PATH:-village-way/zhanlu-code}" # zhanlu_change - default links belong to Zhanlu
# zhanlu_change start - keep wrapper defaults aligned with fetched Zhanlu source
APP_IDENTIFIER="${APP_IDENTIFIER:-Ecloud.Zhanlu}"
APP_IDENTIFIER_BASE="${APP_IDENTIFIER%.Insiders}"
BINARY_NAME_BASE="${BINARY_NAME%-insiders}"
ORG_NAME="${ORG_NAME:-Ecloud}"
TUNNEL_APP_NAME="${TUNNEL_APP_NAME:-"${BINARY_NAME_BASE}-tunnel"}"

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  PRODUCT_APP_IDENTIFIER="${PRODUCT_APP_IDENTIFIER:-"${APP_IDENTIFIER_BASE}.Insiders"}"
  PRODUCT_BINARY_NAME="${PRODUCT_BINARY_NAME:-"${BINARY_NAME_BASE}-insiders"}"
  PRODUCT_TUNNEL_APP_NAME="${PRODUCT_TUNNEL_APP_NAME:-"${BINARY_NAME_BASE}-tunnel-insiders"}"
else
  PRODUCT_APP_IDENTIFIER="${PRODUCT_APP_IDENTIFIER:-"${APP_IDENTIFIER_BASE}"}"
  PRODUCT_BINARY_NAME="${PRODUCT_BINARY_NAME:-"${BINARY_NAME_BASE}"}"
  PRODUCT_TUNNEL_APP_NAME="${PRODUCT_TUNNEL_APP_NAME:-"${TUNNEL_APP_NAME}"}"
fi
# zhanlu_change end

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  GLOBAL_DIRNAME="${GLOBAL_DIRNAME:-"${APP_NAME_LC}"}-insiders"
else
  GLOBAL_DIRNAME="${GLOBAL_DIRNAME:-"${APP_NAME_LC}"}"
fi

# All common functions can be added to this file

apply_patch() {
  if [[ -z "$2" ]]; then
    echo applying patch: "$1";
  fi
  # grep '^+++' "$1"  | sed -e 's#+++ [ab]/#./vscode/#' | while read line; do shasum -a 256 "${line}"; done

  cp $1{,.bak}

  replace "s|!!APP_NAME!!|${APP_NAME}|g" "$1"
  replace "s|!!APP_NAME_LC!!|${APP_NAME_LC}|g" "$1"
  replace "s|!!APP_IDENTIFIER!!|${APP_IDENTIFIER}|g" "$1" # zhanlu_change
  replace "s|!!ASSETS_REPOSITORY!!|${ASSETS_REPOSITORY}|g" "$1"
  replace "s|!!BINARY_NAME!!|${BINARY_NAME}|g" "$1"
  replace "s|!!GH_REPO_PATH!!|${GH_REPO_PATH}|g" "$1"
  replace "s|!!GLOBAL_DIRNAME!!|${GLOBAL_DIRNAME}|g" "$1"
  replace "s|!!ORG_NAME!!|${ORG_NAME}|g" "$1"
  replace "s|!!PRODUCT_APP_IDENTIFIER!!|${PRODUCT_APP_IDENTIFIER}|g" "$1" # zhanlu_change
  replace "s|!!PRODUCT_BINARY_NAME!!|${PRODUCT_BINARY_NAME}|g" "$1" # zhanlu_change
  replace "s|!!RELEASE_VERSION!!|${RELEASE_VERSION}|g" "$1"
  replace "s|!!TUNNEL_APP_NAME!!|${TUNNEL_APP_NAME}|g" "$1"

  if ! git apply --ignore-whitespace "$1"; then
    echo failed to apply patch "$1" >&2
    exit 1
  fi

  mv -f $1{.bak,}
}

exists() { type -t "$1" &> /dev/null; }

is_gnu_sed() {
  sed --version &> /dev/null
}

replace() {
  if is_gnu_sed; then
    sed -i -E "${1}" "${2}"
  else
    sed -i '' -E "${1}" "${2}"
  fi
}

if ! exists gsed; then
  if is_gnu_sed; then
    function gsed() {
      sed -i -E "$@"
    }
  else
    function gsed() {
      sed -i '' -E "$@"
    }
  fi
fi
