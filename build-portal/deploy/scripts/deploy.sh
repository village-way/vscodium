#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 <image@sha256:digest> <deployment.env> <workspace.env> <tls.crt> <tls.key> <github-app.pem>" >&2
  exit 2
fi
image_ref="$1"; deployment_env="$2"; workspace_env="$3"; tls_crt="$4"; tls_key="$5"; app_key="$6"
for file in "$deployment_env" "$workspace_env" "$tls_crt" "$tls_key" "$app_key"; do
  [[ -f "$file" ]] || { echo "missing file: $file" >&2; exit 2; }
done
[[ "$image_ref" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "image must be pinned by sha256 digest" >&2; exit 2; }
openssl x509 -in "$tls_crt" -noout -checkend 86400 >/dev/null || { echo "TLS certificate is invalid or expires within 24 hours" >&2; exit 2; }

read_secret() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}
require_secret() {
  local file="$1" key="$2" value
  value="$(read_secret "$file" "$key")"
  [[ -n "$value" ]] || { echo "missing required secret value: $key" >&2; exit 2; }
  printf '%s' "$value"
}

repositories_json="$(require_secret "$deployment_env" REPOSITORIES_JSON)"
printf '%s' "$repositories_json" | jq -e 'type == "object" and (has("vscodium") and has("zhanlu-cloud") and has("zhanlu-code") and has("zhanlu-core") and has("zhanlu-loc") and has("zhanlu-vs"))' >/dev/null || { echo "REPOSITORIES_JSON must include vscodium and all five components" >&2; exit 2; }
[[ "$(require_secret "$deployment_env" GITHUB_APP_ID)" =~ ^[0-9]+$ ]] || { echo "GITHUB_APP_ID must be numeric" >&2; exit 2; }
[[ "$(require_secret "$deployment_env" GITHUB_APP_INSTALLATION_ID)" =~ ^[0-9]+$ ]] || { echo "GITHUB_APP_INSTALLATION_ID must be numeric" >&2; exit 2; }

tmpdir="$(mktemp -d)"
rendered=""
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT
umask 077
cat >"$tmpdir/runtime.env" <<EOF
SQLITE_PATH=/var/lib/zhanlu-build/state/portal.sqlite3
CONFIRMATION_SECRET=$(require_secret "$deployment_env" CONFIRMATION_SECRET)
IP_HASH_SECRET=$(require_secret "$deployment_env" IP_HASH_SECRET)
CSRF_HMAC_SECRET=$(require_secret "$deployment_env" CSRF_HMAC_SECRET)
PUBLIC_ORIGIN=$(require_secret "$deployment_env" PUBLIC_ORIGIN)
EOF
cat >"$tmpdir/worker.env" <<EOF
GITHUB_APP_ID=$(require_secret "$deployment_env" GITHUB_APP_ID)
GITHUB_APP_INSTALLATION_ID=$(require_secret "$deployment_env" GITHUB_APP_INSTALLATION_ID)
GITHUB_OWNER=$(require_secret "$deployment_env" GITHUB_OWNER)
GITHUB_REPOSITORY_NAME=$(require_secret "$deployment_env" GITHUB_REPOSITORY_NAME)
GITHUB_APP_PRIVATE_KEY_FILE=/run/secrets/github/private-key.pem
GITLAB_TOKEN=$(require_secret "$deployment_env" GITLAB_TOKEN)
GITLAB_HOST=$(require_secret "$deployment_env" GITLAB_HOST)
GITLAB_API_HOST=$(require_secret "$deployment_env" GITLAB_API_HOST)
GITLAB_API_PROTOCOL=$(require_secret "$deployment_env" GITLAB_API_PROTOCOL)
GITLAB_API_PORT=$(require_secret "$deployment_env" GITLAB_API_PORT)
REPOSITORIES_JSON=$repositories_json
PORTAL_VERSION=${image_ref##*@}
EOF
cat >"$tmpdir/bootstrap.env" <<EOF
BOOTSTRAP_ADMIN_USERNAME=$(require_secret "$workspace_env" BOOTSTRAP_ADMIN_USERNAME)
BOOTSTRAP_ADMIN_PASSWORD=$(require_secret "$workspace_env" BOOTSTRAP_ADMIN_PASSWORD)
EOF

base_dir="$(cd "$(dirname "$0")/.." && pwd)"
kubectl apply -f "$base_dir/k8s/base/namespace.yaml"
kubectl -n zhanlu-build create secret generic build-portal-runtime-sqlite --from-env-file="$tmpdir/runtime.env" --dry-run -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret generic build-portal-worker-v2 --from-env-file="$tmpdir/worker.env" --dry-run -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret generic build-portal-github-app --from-file=private-key.pem="$app_key" --dry-run -o yaml | kubectl apply -f -
kubectl -n zhanlu-build create secret tls build-portal-tls --cert="$tls_crt" --key="$tls_key" --dry-run -o yaml | kubectl apply -f -
rendered="$tmpdir/portal.yaml"
kubectl kustomize "$base_dir/k8s/base" | sed "s|SET_IMAGE|${image_ref}|g" >"$rendered"
kubectl apply -f "$rendered"
kubectl -n zhanlu-build rollout status deployment/build-portal --timeout=600s

kubectl -n zhanlu-build create secret generic build-portal-bootstrap --from-env-file="$tmpdir/bootstrap.env" --dry-run -o yaml | kubectl apply -f -
kubectl -n zhanlu-build delete job build-portal-bootstrap-admin --ignore-not-found --wait=true
sed "s|SET_IMAGE|${image_ref}|g" "$base_dir/k8s/bootstrap-job.yaml" | kubectl apply -f -
if ! kubectl -n zhanlu-build wait --for=condition=complete job/build-portal-bootstrap-admin --timeout=180s; then
  kubectl -n zhanlu-build logs job/build-portal-bootstrap-admin --all-containers >&2 || true
  exit 1
fi
kubectl -n zhanlu-build delete job build-portal-bootstrap-admin --wait=true
kubectl -n zhanlu-build delete secret build-portal-bootstrap

initial_backup="sqlite-backup-initial-$(date +%s)"
kubectl -n zhanlu-build get cronjob sqlite-backup -o json | jq --arg name "$initial_backup" '{
  apiVersion: "batch/v1",
  kind: "Job",
  metadata: { name: $name, namespace: "zhanlu-build", labels: { app: "build-portal", component: "backup", architecture: "sqlite", purpose: "initial-backup" } },
  spec: .spec.jobTemplate.spec
}' | kubectl apply -f -
for _ in {1..150}; do
  complete="$(kubectl -n zhanlu-build get job "$initial_backup" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')"
  failed="$(kubectl -n zhanlu-build get job "$initial_backup" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')"
  [[ "$complete" == "True" ]] && break
  if [[ "$failed" == "True" ]]; then
    kubectl -n zhanlu-build logs "job/${initial_backup}" --all-containers >&2 || true
    exit 1
  fi
  sleep 2
done
[[ "$(kubectl -n zhanlu-build get job "$initial_backup" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]] || {
  kubectl -n zhanlu-build logs "job/${initial_backup}" --all-containers >&2 || true
  echo "initial SQLite backup timed out" >&2
  exit 1
}
kubectl -n zhanlu-build logs "job/${initial_backup}" --all-containers
kubectl -n zhanlu-build delete job "$initial_backup" --wait=true
