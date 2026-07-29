# zhanlu_change - new file
# shellcheck shell=bash

resolve_release_delivery_profile() {
    local source_ref="$1"
    local profile_id="$2"
    local current_assets_repository="$3"
    local source_repository="${ZHANLU_CODE_REPOSITORY:-village-way/zhanlu-code}"
    local temp_root
    local archive
    local source_root
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
    mkdir -p "${source_root}"
    if ! gh api "repos/${source_repository}/tarball/${ZHANLU_DELIVERY_SOURCE_COMMIT}" > "${archive}" || \
        ! tar -xzf "${archive}" --strip-components=1 -C "${source_root}" || \
        ! result="$(node "${source_root}/scripts/resolve-delivery-profile.mjs" \
            --profile "${profile_id}" \
            --profiles-root "${source_root}/delivery-profiles" \
            --staging "${temp_root}/staging" \
            --source-commit "${ZHANLU_DELIVERY_SOURCE_COMMIT}")"; then
        rm -rf "${temp_root}"
        return 1
    fi
    ZHANLU_DELIVERY_PROFILE="$(jq -r '.id' <<<"${result}")"
    ZHANLU_DELIVERY_PROFILE_DIGEST="$(jq -r '.profileDigest' <<<"${result}")"
    if [[ "${profile_id}" == "default" ]]; then
        ZHANLU_DELIVERY_ASSETS_REPOSITORY="${current_assets_repository}"
    else
        ZHANLU_DELIVERY_ASSETS_REPOSITORY="$(jq -r '.assetsRepository' <<<"${result}")"
    fi
    rm -rf "${temp_root}"
    export ZHANLU_DELIVERY_PROFILE ZHANLU_DELIVERY_SOURCE_COMMIT
    export ZHANLU_DELIVERY_PROFILE_DIGEST ZHANLU_DELIVERY_ASSETS_REPOSITORY
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
    jq -n \
        --arg profile "${ZHANLU_DELIVERY_PROFILE:-default}" \
        --arg releaseVersion "${RELEASE_VERSION:-${VERSION:-}}" \
        --arg sourceRef "${SOURCE_BRANCH:-develop}" \
        --arg sourceCommit "${ZHANLU_DELIVERY_SOURCE_COMMIT:-}" \
        --arg profileDigest "${ZHANLU_DELIVERY_PROFILE_DIGEST:-}" \
        --arg assetsRepository "${ZHANLU_DELIVERY_ASSETS_REPOSITORY:-${ASSETS_REPOSITORY}}" \
        '{schemaVersion:1,releaseVersion:$releaseVersion,deliveryProfile:$profile,sourceRef:$sourceRef,sourceCommit:$sourceCommit,profileDigest:$profileDigest,assetsRepository:$assetsRepository}' \
        > "${output}"
}
