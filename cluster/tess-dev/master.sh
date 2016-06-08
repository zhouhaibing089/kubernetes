#!/bin/bash

# install etcd
if ! which etcd &>/dev/null; then
  echo "install etcd"
  curl -L  https://github.com/coreos/etcd/releases/download/v2.3.4/etcd-v2.3.4-linux-amd64.tar.gz -o etcd-v2.3.4-linux-amd64.tar.gz &>/dev/null
  tar xzf etcd-v2.3.4-linux-amd64.tar.gz
  pushd etcd-v2.3.4-linux-amd64 &>/dev/null
  cp etcd ${BINDIR}/
  cp etcdctl ${BINDIR}/
  popd &>/dev/null
  rm -f etcd-v2.3.4-linux-amd64.tar.gz
  rm -drf etcd-v2.3.4-linux-amd64
  ETCD=${BINDIR}/etcd
else
  # atomic already ships etcd
  ETCD=etcd
fi

# start etcd
pid=$(process-id etcd)
if [[ -n $pid ]]; then
  echo "etcd is already running"
else
  echo "start etcd"
  ${ETCD} 1>>/var/log/etcd.log 2>&1 &
fi

weave-setup ${NODE_IP}

# need a keyfile for service account
if [[ ! -d /etc/ssl/kubernetes ]]; then
  mkdir -p /etc/ssl/kubernetes
fi
ServiceAccountKeyFile="/etc/ssl/kubernetes/serviceaccount.key"
if [[ ! -f ${ServiceAccountKeyFile} ]]; then
  echo "generate private key file for service account"
  openssl genpkey -algorithm RSA -out ${ServiceAccountKeyFile} &>/dev/null
fi

# ensure the abac policy file exists
cat <<EOF > /etc/sysconfig/abac.json
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"${OS_USERNAME}","namespace": "*","resource": "*","nonResourcePath": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"group":"${OS_TENANT_NAME}","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:serviceaccount:kube-system:default","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:monitoring","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:dns","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:read-only", "readonly": true, "namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:tess_master","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:logging","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:controller_manager","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"system:scheduler","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"kube_proxy","namespace": "*","resource": "*","apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user":"kubelet","namespace": "*","resource": "*","apiGroup": "*"}}
EOF

# start apiserver
setup-binary "kube-apiserver"
# if the cert/key has already been generated, do not let the push overrides it
if [[ -f /var/run/kubernetes/apiserver.crt ]]; then
  API_SERVER_ARGS="${API_SERVER_ARGS} \
    --tls-cert-file=/var/run/kubernetes/apiserver.crt \
    --tls-private-key-file=/var/run/kubernetes/apiserver.key"
fi
${BINDIR}/kube-apiserver --etcd-servers=http://127.0.0.1:2379 \
  --insecure-bind-address=0.0.0.0 \
  --admission-control=${ADMISSION_CONTROL} \
  --authorization-mode=${AUTHORIZATION_MODE} \
  --runtime-config=${RUNTIME_CONFIG} \
  --service-cluster-ip-range=192.168.0.0/16 \
  --service-account-key-file=${ServiceAccountKeyFile} \
  ${API_SERVER_ARGS} \
  --v=10 \
  1>>/var/log/kube-apiserver.log 2>&1 &

# before we start kube-controller-manager, we will wait until the ca is generated
while [[ ! -f /var/run/kubernetes/apiserver.crt ]]; do
  sleep 1
done

# start kube-controller-manager
setup-binary "kube-controller-manager"
${BINDIR}/kube-controller-manager --master=http://127.0.0.1:8080 \
  --service-account-private-key-file=${ServiceAccountKeyFile} \
  --root-ca-file=/var/run/kubernetes/apiserver.crt \
  --v=10 \
  1>>/var/log/kube-controller-manager.log 2>&1 &

# start kube-scheduler
setup-binary "kube-scheduler"
${BINDIR}/kube-scheduler --master=http://127.0.0.1:8080 \
  --v=10 \
  1>>/var/log/kube-scheduler.log 2>&1 &

# start to run kubelet and kube-proxy
start-kubelet
start-kube-proxy

# copy kubectl to PATH
cp ${PREFIX}/kubectl ${BINDIR}
