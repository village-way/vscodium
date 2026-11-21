# zhanlu_change - new file
# shellcheck shell=bash

resolve_release_delivery_profile() {
    # The portal already checked the source data with image-pinned tooling.
    # Read the confirmed snapshot without loading any scripts from the selected build source.
    if [[ -n "${ZL_FROZEN_DELIVERY_FILE:-}" ]]; then
        local file="${ZL_FROZEN_DELIVERY_FILE}"
        jq -e --arg profile "$2" --arg sha "${ZHANLU_DELIVERY_SOURCE_COMMIT:?}" --arg digest "${ZHANLU_DELIVERY_PROFILE_DIGEST:?}" \
          '.schemaVersion == 2 and .id == $profile and .sourceCommit == $sha and .profileDigest == $digest' "$file" >/dev/null || return 1
        ZHANLU_DELIVERY_SCHEMA_VERSION=2
        ZHANLU_DELIVERY_PROFILE="$2"
        ZHANLU_DELIVERY_ASSETS_REPOSITORY="$(jq -er '.assetsRepository' "$file")" || return 1
        ZHANLU_DELIVERY_CONFIG="$(jq -ec '.deliveryConfig' "$file")" || return 1
        ZHANLU_DELIVERY_EXPECTED_ASSETS="$(jq -ec '.expectedAssets' "$file")" || return 1
        export ZHANLU_DELIVERY_SCHEMA_VERSION ZHANLU_DELIVERY_PROFILE ZHANLU_DELIVERY_CONFIG
        export ZHANLU_DELIVERY_ASSETS_REPOSITORY ZHANLU_DELIVERY_EXPECTED_ASSETS
        return 0
    fi
    if [[ -n "${SOURCE_CHECKOUT_ROOT:-}" ]]; then
        if [[ -n "${SOURCE_SUBDIR:-}" && ! "${SOURCE_SUBDIR}" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$ ]]; then
            echo 'Invalid source layout.' >&2
            return 1
        fi
        source "${SOURCE_CHECKOUT_ROOT}${SOURCE_SUBDIR:+/${SOURCE_SUBDIR}}/scripts/resolve-release-delivery-profile.sh"
        resolve_release_delivery_profile "$@"
        return
    fi
    local source_ref="$1"
    local profile_id="$2"
    local current_assets_repository="$3"
    local source_repository="${ZHANLU_CODE_REPOSITORY:-${SOURCE_REPOSITORY:-}}"
    local temp_root
    local archive
    local source_root
    local package_root
    local result
    local encoded_ref

    encoded_ref="$(jq -rn --arg value "${source_ref}" '$value|@uri')"
    ZHANLU_DELIVERY_SOURCE_COMMIT="$(gh api "repos/${source_repository}/commits/${encoded_ref}" --jq '.sha')"
    if [[ ! "${ZHANLU_DELIVERY_SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: failed to resolve ${source_repository}@${source_ref}" >&2
        return 1
    fi

    # The default profile ships staged plugins too, so its digest has to be resolved from the pinned
    # source instead of a constant.
    temp_root="$(mktemp -d "${TMPDIR:-/tmp}/zhanlu-release-profile.XXXXXX")"
    archive="${temp_root}/source.tar.gz"
    source_root="${temp_root}/source"
    # The build tree may be a subdirectory of the source repository.
    if [[ -n "${SOURCE_SUBDIR:-}" && ! "${SOURCE_SUBDIR}" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$ ]]; then
        echo "Error: SOURCE_SUBDIR must be a relative directory inside the source repository" >&2
        rm -rf "${temp_root}"
        return 1
    fi
    package_root="${source_root}${SOURCE_SUBDIR:+/${SOURCE_SUBDIR}}"
    mkdir -p "${source_root}"
    if ! gh api "repos/${source_repository}/tarball/${ZHANLU_DELIVERY_SOURCE_COMMIT}" > "${archive}" || \
        ! tar -xzf "${archive}" --strip-components=1 -C "${source_root}" || \
        ! result="$(node "${package_root}/scripts/resolve-delivery-profile.mjs" \
            --profile "${profile_id}" \
            --profiles-root "${package_root}/delivery-profiles" \
            --staging "${temp_root}/staging" \
            --source-commit "${ZHANLU_DELIVERY_SOURCE_COMMIT}")"; then
        rm -rf "${temp_root}"
        return 1
    fi
    # freeze the resolver contract without reinterpreting legacy profiles
    ZHANLU_DELIVERY_SCHEMA_VERSION="$(jq -r '.schemaVersion' <<<"${result}")"
    ZHANLU_DELIVERY_CONFIG="$(jq -c '.deliveryConfig // null' <<<"${result}")"
    export ZHANLU_DELIVERY_SCHEMA_VERSION ZHANLU_DELIVERY_CONFIG
    ZHANLU_DELIVERY_PROFILE="$(jq -r '.id' <<<"${result}")"
    ZHANLU_DELIVERY_PROFILE_DIGEST="$(jq -r '.profileDigest' <<<"${result}")"
    if [[ "${profile_id}" == "default" ]]; then
        ZHANLU_DELIVERY_ASSETS_REPOSITORY="${current_assets_repository}"
    else
        ZHANLU_DELIVERY_ASSETS_REPOSITORY="$(jq -r '.assetsRepository' <<<"${result}")"
    fi
    # Resolve expectations from the pinned private source, never from uploaded assets.
    local resolved_app_name="${APP_NAME:-}" resolved_app_name_lc="${APP_NAME_LC:-}" resolved_binary_name="${BINARY_NAME:-}"
    if [[ "${ZHANLU_DELIVERY_SCHEMA_VERSION}" == "2" ]]; then
        resolved_app_name="$(jq -r '.brand.nameShort' <<<"${ZHANLU_DELIVERY_CONFIG}")"
        resolved_app_name_lc="$(tr '[:upper:]' '[:lower:]' <<<"${resolved_app_name}")"
        resolved_binary_name="$(jq -r '.identity.applicationName' <<<"${ZHANLU_DELIVERY_CONFIG}")"
    fi
    if ! ZHANLU_DELIVERY_EXPECTED_ASSETS="$(APP_NAME="${resolved_app_name}" APP_NAME_LC="${resolved_app_name_lc}" BINARY_NAME="${resolved_binary_name}" bash "${package_root}/scripts/check-release-status.sh" '__RELEASE_VERSION__' "${current_assets_repository}" --expected-json)"; then
        rm -rf "${temp_root}"
        return 1
    fi
    if [[ -f "${package_root}/release_notes.md" ]]; then
        ZHANLU_RELEASE_NOTES_TEMPLATE="$(mktemp)"
        cp "${package_root}/release_notes.md" "${ZHANLU_RELEASE_NOTES_TEMPLATE}"
        if [[ -n "${TMP_FILES+x}" ]]; then
            TMP_FILES+=("${ZHANLU_RELEASE_NOTES_TEMPLATE}")
        fi
    fi
    rm -rf "${temp_root}"
    export ZHANLU_DELIVERY_PROFILE ZHANLU_DELIVERY_SOURCE_COMMIT
    export ZHANLU_DELIVERY_PROFILE_DIGEST ZHANLU_DELIVERY_ASSETS_REPOSITORY
    export ZHANLU_RELEASE_NOTES_TEMPLATE ZHANLU_DELIVERY_EXPECTED_ASSETS
}

prepare_release_delivery_profile() {
    local source_ref="$1"
    local profile_id="$2"
    local current_assets_repository="$3"
    local requested_commit="${ZHANLU_DELIVERY_SOURCE_COMMIT:-}"
    local requested_digest="${ZHANLU_DELIVERY_PROFILE_DIGEST:-}"
    local requested_repository="${ZHANLU_DELIVERY_ASSETS_REPOSITORY:-}"

    resolve_release_delivery_profile "${requested_commit:-${source_ref}}" "${profile_id}" "${current_assets_repository}"
    if [[ -n "${requested_commit}" && "${ZHANLU_DELIVERY_SOURCE_COMMIT}" != "${requested_commit}" ]]; then
        echo "Error: delivery source commit does not match the validated profile" >&2
        return 1
    fi
    if [[ -n "${requested_digest}" && "${ZHANLU_DELIVERY_PROFILE_DIGEST}" != "${requested_digest}" ]]; then
        echo "Error: delivery profile digest does not match the validated source" >&2
        return 1
    fi
    if [[ -n "${requested_repository}" && "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" != "${requested_repository}" ]]; then
        echo "Error: delivery assets repository is not allowed by the validated profile" >&2
        return 1
    fi
}

write_release_delivery_metadata() {
    local output="$1"
    # v2 records offline delivery and the exact confirmed build inputs
    if [[ "${ZHANLU_DELIVERY_SCHEMA_VERSION:-1}" == "2" ]]; then
        local workflow_commit="${ZHANLU_DELIVERY_WORKFLOW_COMMIT:-${RELEASE_WORKFLOW_COMMIT:-${GITHUB_SHA:-}}}"
        [[ "${workflow_commit}" =~ ^[a-f0-9]{40}$ ]] || { echo 'v2 delivery requires an exact workflow commit' >&2; return 1; }
        jq -n \
            --arg version "${RELEASE_VERSION:-${VERSION:-}}" --arg tag "${RELEASE_TAG:?missing release tag}" \
            --arg profile "${ZHANLU_DELIVERY_PROFILE}" --arg ref "${SOURCE_BRANCH:-develop}" \
            --arg source "${ZHANLU_DELIVERY_SOURCE_COMMIT}" --arg digest "${ZHANLU_DELIVERY_PROFILE_DIGEST}" \
            --arg repository "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" --arg workflow "${workflow_commit}" \
            --argjson options "${ZHANLU_DELIVERY_BUILD_OPTIONS:?missing confirmed build options}" \
            --argjson expected "${ZHANLU_DELIVERY_EXPECTED_ASSETS:?missing artifact contract}" \
            '{schemaVersion:2,deliveryMode:"offline",releaseVersion:$version,releaseTag:$tag,deliveryProfile:$profile,sourceRef:$ref,sourceCommit:$source,workflowCommit:$workflow,profileDigest:$digest,assetsRepository:$repository,buildOptions:$options,expectedAssets:($expected|walk(if type=="string" then gsub("__RELEASE_VERSION__";$version) else . end))}' > "${output}"
        return
    fi
    jq -n \
        --arg profile "${ZHANLU_DELIVERY_PROFILE:-default}" \
        --arg releaseVersion "${RELEASE_VERSION:-${VERSION:-}}" \
        --arg sourceRef "${SOURCE_BRANCH:-develop}" \
        --arg sourceCommit "${ZHANLU_DELIVERY_SOURCE_COMMIT:-}" \
        --arg profileDigest "${ZHANLU_DELIVERY_PROFILE_DIGEST:-}" \
        --arg assetsRepository "${ZHANLU_DELIVERY_ASSETS_REPOSITORY:-${ASSETS_REPOSITORY}}" \
        --argjson expectedAssets "${ZHANLU_DELIVERY_EXPECTED_ASSETS:?missing artifact contract}" \
        '{schemaVersion:1,releaseVersion:$releaseVersion,deliveryProfile:$profile,sourceRef:$sourceRef,sourceCommit:$sourceCommit,profileDigest:$profileDigest,assetsRepository:$assetsRepository,expectedAssets:($expectedAssets | walk(if type == "string" then gsub("__RELEASE_VERSION__";$releaseVersion) else . end))}' \
        > "${output}"
}

# compare every frozen v2 input before writing to a previously created target
assert_release_delivery_metadata() {
    local metadata="$1" expected
    [[ "${ZHANLU_DELIVERY_SCHEMA_VERSION:-1}" == "2" ]] || return 0
    expected="$(mktemp)"
    if ! write_release_delivery_metadata "${expected}" || ! jq -e --slurpfile expected "${expected}" \
        'del(.artifacts) == $expected[0]' "${metadata}" >/dev/null; then
        rm -f "${expected}"
        echo 'Existing target does not match the confirmed delivery inputs' >&2
        return 1
    fi
    rm -f "${expected}"
}
