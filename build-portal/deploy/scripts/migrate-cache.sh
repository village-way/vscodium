#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "usage: $0 <image@sha256:digest>" >&2
  exit 2
fi
image_ref="$1"
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
cat >"$tmpfile" <<EOF
apiVersion: batch/v1
kind: Job
metadata: { name: build-portal-cache-migrate, namespace: zhanlu-build }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { app: build-portal, component: cache-migrate } }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector: { kubernetes.io/hostname: pve-nas }
      containers:
        - name: migrate
          image: ${image_ref}
          command: [/bin/bash, -ceu]
          args:
            - |
              install -d -o 10001 -g 10001 -m 0750 /new
              for repository in zhanlu-cloud zhanlu-code zhanlu-core zhanlu-loc zhanlu-vs; do
                source="/legacy/git-sync/cache/\${repository}.git"
                target="/new/\${repository}.git"
                test -d "\$source"
                if [[ ! -d "\$target" ]]; then cp -a -- "\$source" "\$target"; fi
                chown -R 10001:10001 "\$target"
                gitlab_head="\$(git --git-dir="\$target" rev-parse refs/remotes/gitlab/develop)"
                git --git-dir="\$target" update-ref refs/heads/develop "\$gitlab_head"
                git --git-dir="\$target" symbolic-ref HEAD refs/heads/develop
                git --git-dir="\$target" rev-parse --is-bare-repository
                git --git-dir="\$target" fsck --no-dangling
              done
          securityContext: { runAsUser: 0, runAsGroup: 0, allowPrivilegeEscalation: false, capabilities: { drop: [ALL], add: [CHOWN, DAC_OVERRIDE, FOWNER] } }
          volumeMounts: [{ name: legacy, mountPath: /legacy, readOnly: true }, { name: new, mountPath: /new }]
      volumes:
        - { name: legacy, persistentVolumeClaim: { claimName: worker-data } }
        - { name: new, hostPath: { path: /vol1/1000/k8s-build/build-portal/git-cache, type: DirectoryOrCreate } }
EOF
kubectl -n zhanlu-build delete job build-portal-cache-migrate --ignore-not-found --wait=true
kubectl apply -f "$tmpfile"
for _ in {1..450}; do
  complete="$(kubectl -n zhanlu-build get job build-portal-cache-migrate -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')"
  failed="$(kubectl -n zhanlu-build get job build-portal-cache-migrate -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')"
  [[ "$complete" == "True" ]] && break
  if [[ "$failed" == "True" ]]; then
    kubectl -n zhanlu-build logs job/build-portal-cache-migrate --all-containers >&2 || true
    exit 1
  fi
  sleep 2
done
[[ "$(kubectl -n zhanlu-build get job build-portal-cache-migrate -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]] || {
  kubectl -n zhanlu-build logs job/build-portal-cache-migrate --all-containers >&2 || true
  echo "cache migration timed out" >&2
  exit 1
}
kubectl -n zhanlu-build logs job/build-portal-cache-migrate --all-containers
kubectl -n zhanlu-build delete job build-portal-cache-migrate --wait=true
