#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 3 ]]; then echo "usage: $0 <git-sha> <username> <password-file>" >&2; exit 2; fi
git_sha="$1"; username="$2"; password_file="$3"; [[ -f "$password_file" ]] || { echo "password file not found" >&2; exit 2; }
[[ "$username" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || { echo "username must contain only letters, numbers, dot, underscore or hyphen" >&2; exit 2; }
password="$(<"$password_file")"; [[ ${#password} -ge 16 ]] || { echo "password must contain at least 16 characters" >&2; exit 2; }
kubectl -n zhanlu-build delete job build-portal-bootstrap-admin --ignore-not-found
tmpdir="$(mktemp -d)"; rendered="$tmpdir/bootstrap.yaml"; trap 'kubectl -n zhanlu-build delete secret build-portal-bootstrap --ignore-not-found >/dev/null; rm -rf "$tmpdir"' EXIT
umask 077
printf 'BOOTSTRAP_ADMIN_USERNAME=%s\nBOOTSTRAP_ADMIN_PASSWORD=%s\n' "$username" "$password" > "$tmpdir/bootstrap.env"
kubectl -n zhanlu-build create secret generic build-portal-bootstrap --from-env-file="$tmpdir/bootstrap.env" --dry-run=client -o yaml | kubectl apply -f -
sed "s/SET_GIT_SHA/${git_sha}/g" "$(dirname "$0")/../k8s/bootstrap-job.yaml" > "$rendered"
kubectl apply -f "$rendered"
kubectl -n zhanlu-build wait --for=condition=complete job/build-portal-bootstrap-admin --timeout=180s
kubectl -n zhanlu-build delete secret build-portal-bootstrap
