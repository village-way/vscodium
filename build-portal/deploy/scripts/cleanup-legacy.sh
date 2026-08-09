#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "usage: $0 <image@sha256:digest>" >&2
  exit 2
fi
image_ref="$1"
namespace="zhanlu-build"
claims=(worker-data postgres-data postgres-backup)
declare -a volumes=() paths=()

kubectl -n "$namespace" rollout status deployment/build-portal --timeout=60s
[[ "$(kubectl -n "$namespace" get deployment build-portal -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}')" == "pve-nas" ]] || { echo "new portal is not pinned to pve-nas" >&2; exit 1; }
kubectl -n "$namespace" get cronjob sqlite-backup >/dev/null

for claim in "${claims[@]}"; do
  volume="$(kubectl -n "$namespace" get pvc "$claim" -o jsonpath='{.spec.volumeName}')"
  path_value="$(kubectl get pv "$volume" -o jsonpath='{.spec.nfs.path}')"
  server="$(kubectl get pv "$volume" -o jsonpath='{.spec.nfs.server}')"
  [[ "$server" == "192.168.22.109" ]] || { echo "unexpected NFS server for $claim: $server" >&2; exit 1; }
  [[ "$path_value" =~ ^/vol1/1000/k8s-build/zhanlu-build-(worker-data|postgres-data|postgres-backup)-pvc-[0-9a-f-]{36}$ ]] || { echo "refusing unexpected NFS path for $claim: $path_value" >&2; exit 1; }
  [[ "$(kubectl get pv "$volume" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}')" == "$namespace/$claim" ]] || { echo "PV claimRef mismatch for $claim" >&2; exit 1; }
  volumes+=("$volume")
  paths+=("$path_value")
  echo "verified legacy target: $claim -> $volume -> $path_value"
done

kubectl -n "$namespace" delete deployment build-portal-web build-portal-worker build-portal-scheduler --ignore-not-found --wait=true
kubectl -n "$namespace" delete statefulset postgres --ignore-not-found --wait=true
kubectl -n "$namespace" delete service postgres --ignore-not-found
kubectl -n "$namespace" delete cronjob postgres-backup --ignore-not-found
kubectl -n "$namespace" delete job build-portal-migrate build-portal-bootstrap-admin --ignore-not-found --wait=true
kubectl -n "$namespace" delete job -l batch.kubernetes.io/cronjob-name=postgres-backup --ignore-not-found --wait=true
kubectl -n "$namespace" delete secret build-portal-db build-portal-runtime build-portal-worker --ignore-not-found
kubectl -n "$namespace" delete networkpolicy database-clients postgres scheduler web worker --ignore-not-found
kubectl -n "$namespace" delete pvc "${claims[@]}" --wait=true

for volume in "${volumes[@]}"; do
  for _ in {1..60}; do
    kubectl get pv "$volume" >/dev/null 2>&1 || break
    sleep 2
  done
  kubectl get pv "$volume" >/dev/null 2>&1 && { echo "PV was not deleted: $volume" >&2; exit 1; }
done

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
cleanup_commands=""
for path_value in "${paths[@]}"; do
  base="${path_value##*/}"
  cleanup_commands+="rm -rf -- /nfs/${base}"$'\n'
done
cat >"$tmpfile" <<EOF
apiVersion: v1
kind: Pod
metadata: { name: build-portal-storage-cleanup, namespace: zhanlu-build }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  nodeSelector: { kubernetes.io/hostname: pve-nas }
  containers:
    - name: cleanup
      image: ${image_ref}
      command: [/bin/bash, -ceu]
      args:
        - |
$(printf '%s' "$cleanup_commands" | sed 's/^/          /')
      securityContext: { runAsUser: 0, runAsGroup: 0, allowPrivilegeEscalation: false, capabilities: { drop: [ALL], add: [DAC_OVERRIDE] } }
      volumeMounts: [{ name: nfs-root, mountPath: /nfs }]
  volumes:
    - { name: nfs-root, hostPath: { path: /vol1/1000/k8s-build, type: Directory } }
EOF
kubectl -n "$namespace" delete pod build-portal-storage-cleanup --ignore-not-found --wait=true
kubectl apply -f "$tmpfile"
for _ in {1..90}; do
  phase="$(kubectl -n "$namespace" get pod build-portal-storage-cleanup -o jsonpath='{.status.phase}')"
  [[ "$phase" == "Succeeded" ]] && break
  [[ "$phase" == "Failed" ]] && { kubectl -n "$namespace" logs build-portal-storage-cleanup >&2 || true; exit 1; }
  sleep 2
done
[[ "$(kubectl -n "$namespace" get pod build-portal-storage-cleanup -o jsonpath='{.status.phase}')" == "Succeeded" ]] || { echo "storage cleanup pod timed out" >&2; exit 1; }
kubectl -n "$namespace" delete pod build-portal-storage-cleanup --wait=true

kubectl -n default delete deployment zhanlu-build-nfs-provisioner --ignore-not-found --wait=true
kubectl delete storageclass zhanlu-build-nfs-storage --ignore-not-found
kubectl -n default delete rolebinding leader-locking-zhanlu-build-nfs-provisioner --ignore-not-found
kubectl -n default delete role leader-locking-zhanlu-build-nfs-provisioner --ignore-not-found
kubectl delete clusterrolebinding zhanlu-build-nfs-provisioner --ignore-not-found
kubectl -n default delete serviceaccount zhanlu-build-nfs-provisioner --ignore-not-found

kubectl -n "$namespace" get deployment build-portal
kubectl -n "$namespace" get cronjob sqlite-backup
if kubectl -n "$namespace" get pvc >/dev/null 2>&1 && [[ -n "$(kubectl -n "$namespace" get pvc -o name)" ]]; then
  echo "unexpected PVC remains in $namespace" >&2
  kubectl -n "$namespace" get pvc >&2
  exit 1
fi
