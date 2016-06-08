#! /bin/bash

# generic setttings
export ENABLE_KUBE_DNS=${ENABLE_KUBE_DNS:-false}

# kube-apiserver
export ADMISSION_CONTROL=${ADMISSION_CONTROL:-"NamespaceGuard,ServiceAccount,ResourceQuota,LimitRanger"}
export AUTHORIZATION_MODE=${AUTHORIZATION_MODE:-"ABAC,Annotation"}
export API_SERVER_ARGS=${API_SERVER_ARGS:-""}
export API_SERVER_ARGS="${API_SERVER_ARGS} --keystone_url=https://os-identity.vip.ebayc3.com:5443/v2.0 \
  --authorization_policy_file=/etc/sysconfig/abac.json"
export RUNTIME_CONFIG="api/v1,extensions/v1beta1,extensions/v1beta1/podsecuritypolicy,extensions/v1beta1/thirdpartyresources"

# kubelet
export KUBELET_ARGS=${KUBELET_ARGS:-""}
