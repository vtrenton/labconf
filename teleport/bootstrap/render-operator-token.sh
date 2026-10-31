#!/bin/sh
# Prints the operator's join token, pinned to infralab's current
# service-account signing keys (JWKS). The operator joins with the Kubernetes
# "static_jwks" method: no secret anywhere, but the keys change whenever
# infralab is rebuilt, so re-run this after every rebuild:
#
#   ./teleport/bootstrap/render-operator-token.sh > /tmp/operator-token.yaml
#   tctl create /tmp/operator-token.yaml      (first time)
#   tctl create -f /tmp/operator-token.yaml   (after a rebuild; -f = --force)
#
# The JWKS is public key material. The output is not written into the repo
# only because it is regenerated per rebuild.
set -eu
: "${KUBECONFIG:=$HOME/.kube/infralab-k3s.yaml}"
export KUBECONFIG
jwks=$(kubectl get --raw /openid/v1/jwks)
cat <<YAML
kind: token
version: v2
metadata:
  name: labconf-operator
  description: Teleport Kubernetes Operator in infralab (static JWKS, re-render after rebuilds)
spec:
  roles: [Bot]
  bot_name: labconf-operator
  join_method: kubernetes
  kubernetes:
    type: static_jwks
    static_jwks:
      jwks: |
        $jwks
    allow:
      # namespace:serviceaccount of the operator (infralab/argo-apps/teleport-operator)
      - service_account: "teleport-iac:teleport-operator"
YAML
