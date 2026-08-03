#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 5 ]]; then echo "usage: $0 <git-sha> <secrets.env> <tls.crt> <tls.key> <github-app.pem>" >&2; exit 2; fi
git_sha="$1"; secrets_file="$2"; tls_crt="$3"; tls_key="$4"; app_key="$5"
for file in "$secrets_file" "$tls_crt" "$tls_key" "$app_key"; do [[ -f "$file" ]] || { echo "missing file: $file" >&2; exit 2; }; done
[[ "$git_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "git SHA must contain 40 lowercase hex characters" >&2; exit 2; }
openssl x509 -in "$tls_crt" -noout -ext subjectAltName | grep -q 'IP Address:192.168.22.100' || { echo "TLS certificate SAN must include 192.168.22.100" >&2; exit 2; }
read_secret() {
  local key="$1"
  sed -n "s/^${key}=//p" "$secrets_file" | head -n 1
}
require_secret() {
  local key="$1" value
  value="$(read_secret "$key")"
  [[ -n "$value" ]] || { echo "missing required secret value: $key" >&2; exit 2; }
  printf '%s' "$value"
}
repositories_json="$(require_secret REPOSITORIES_JSON)"
printf '%s' "$repositories_json" | jq -e 'type == "object" and (has("vscodium") and has("zhanlu-cloud") and has("zhanlu-code") and has("zhanlu-core") and has("zhanlu-loc") and has("zhanlu-vs"))' >/dev/null || { echo "REPOSITORIES_JSON must include vscodium and all five zhanlu components" >&2; exit 2; }
[[ "$(require_secret GITHUB_APP_ID)" =~ ^[0-9]+$ ]] || { echo "GITHUB_APP_ID must be numeric" >&2; exit 2; }
[[ "$(require_secret GITHUB_APP_INSTALLATION_ID)" =~ ^[0-9]+$ ]] || { echo "GITHUB_APP_INSTALLATION_ID must be numeric" >&2; exit 2; }
tmpdir="$(mktemp -d)"
rendered=""
cleanup() {
  if [[ -n "$rendered" ]]; then
    rm -f "$rendered"
    rmdir "$(dirname "$rendered")" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
umask 077
cat > "$tmpdir/db.env" <<EOF
username=$(require_secret DB_USERNAME)
password=$(require_secret DB_PASSWORD)
url=$(require_secret DATABASE_URL)
EOF
cat > "$tmpdir/runtime.env" <<EOF
DATABASE_URL=$(require_secret DATABASE_URL)
CONFIRMATION_SECRET=$(require_secret CONFIRMATION_SECRET)
IP_HASH_SECRET=$(require_secret IP_HASH_SECRET)
CSRF_HMAC_SECRET=$(require_secret CSRF_HMAC_SECRET)
PUBLIC_ORIGIN=$(require_secret PUBLIC_ORIGIN)
EOF
cat > "$tmpdir/worker.env" <<EOF
GITHUB_APP_ID=$(require_secret GITHUB_APP_ID)
GITHUB_APP_INSTALLATION_ID=$(require_secret GITHUB_APP_INSTALLATION_ID)
GITHUB_OWNER=$(require_secret GITHUB_OWNER)
GITHUB_REPOSITORY_NAME=$(require_secret GITHUB_REPOSITORY_NAME)
GITHUB_APP_PRIVATE_KEY_FILE=/run/secrets/github/private-key.pem
GITHUB_GIT_TOKEN=$(require_secret GITHUB_GIT_TOKEN)
GITLAB_TOKEN=$(require_secret GITLAB_TOKEN)
GITLAB_HOST=$(require_secret GITLAB_HOST)
GITLAB_API_HOST=$(require_secret GITLAB_API_HOST)
GITLAB_API_PROTOCOL=$(require_secret GITLAB_API_PROTOCOL)
GITLAB_API_PORT=$(require_secret GITLAB_API_PORT)
REPOSITORIES_JSON=$repositories_json
EOF
kubectl apply -f "$(dirname "$0")/../k8s/base/namespace.yaml"
kubectl apply -f "$(dirname "$0")/../k8s/nfs-build-storage.yaml"
kubectl -n default rollout status deployment/zhanlu-build-nfs-provisioner --timeout=180s
kubectl -n zhanlu-build create secret generic build-portal-db --from-env-file="$tmpdir/db.env" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret generic build-portal-runtime --from-env-file="$tmpdir/runtime.env" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret generic build-portal-worker --from-env-file="$tmpdir/worker.env" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret generic build-portal-github-app --from-file=private-key.pem="$app_key" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret tls build-portal-tls --cert="$tls_crt" --key="$tls_key" --dry-run=client -o yaml | kubectl apply -f -
rendered="$(mktemp -d)/portal.yaml"
kubectl kustomize "$(dirname "$0")/../k8s/base" | sed "s/SET_GIT_SHA/${git_sha}/g" > "$rendered"
kubectl -n zhanlu-build apply -f "$(dirname "$0")/../k8s/base/storage.yaml"
kubectl -n zhanlu-build apply -f "$(dirname "$0")/../k8s/base/postgres.yaml"
kubectl -n zhanlu-build rollout status statefulset/postgres --timeout=300s
kubectl -n zhanlu-build delete job build-portal-migrate --ignore-not-found
sed "s/SET_GIT_SHA/${git_sha}/g" "$(dirname "$0")/../k8s/base/migration.yaml" | kubectl -n zhanlu-build apply -f -
kubectl -n zhanlu-build wait --for=condition=complete job/build-portal-migrate --timeout=180s
kubectl apply -f "$rendered"
kubectl -n zhanlu-build rollout status deployment/build-portal-web --timeout=300s
kubectl -n zhanlu-build rollout status deployment/build-portal-scheduler --timeout=300s
kubectl -n zhanlu-build rollout status deployment/build-portal-worker --timeout=300s
