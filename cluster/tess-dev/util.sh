#! /bin/bash

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${KUBE_ROOT}/cluster/common.sh"
source "${KUBE_ROOT}/hack/lib/init.sh"

KUBECTL="${KUBE_ROOT}/cluster/kubectl.sh"

# the ssh key name
SSH_KEY_NAME=${SSH_KEY_NAME:-"tessdev_${OS_REGION_NAME}_${USER}"}
# number of nodes
NUM_NODES=${NUM_NODES:-1}
export NUM_NODES

BINDIR=/usr/local/bin

# the image id used
IMAGE_ID=${IMAGE_ID-"8872deb8-5763-4d85-80e3-c8c998600664"}

# decide the environment variable
source ${KUBE_ROOT}/cluster/tess-dev/config-${BRANCH:-"tess"}.sh

# conditional settings
if ${ENABLE_KUBE_DNS}; then
  export KUBELET_ARGS="${KUBELET_ARGS} --cluster-dns='192.168.0.10' \
    --cluster-domain='kubernetes.local'"
fi

function kube-up {
  ensure-ssh-key
  decide-image
  boot-nodes
  wait-active
  deploy-binaries

  master-setup
  node-setup

  expose-network
  write-kubeconfig

  create-addons
}

function kube-push {
  detect-master
  detect-nodes

  deploy-binaries
  master-setup
  node-setup
}

function kube-down {
  detect-master
  detect-nodes

  # tear down nodes first
  kube::log::status "tear down nodes"
  for node in ${NODE_IPS[@]}; do
    uuid=$(exec-command $node "cat /var/lib/cloud/data/instance-id")
    kube::log::status "    $uuid"
    nova delete $uuid &>/dev/null
  done
  # then master
  kube::log::status "tear down master"
  uuid=$(exec-command ${MASTER_IP} "cat /var/lib/cloud/data/instance-id")
  kube::log::status "    $uuid"
  nova delete $uuid &>/dev/null
}

function verify-prereqs {
  # ensure kubectl is compiled
  if [[ -z "$(kube::util::find-binary "kubectl")" ]]; then
    kube::log::status "kubectl not found, trying build one"
    ${KUBE_ROOT}/hack/build-go.sh cmd/kubectl
  fi
}

function validate-cluster {
  echo "TODO: validate-cluster"
}

function detect-master {
  name=$(${KUBECTL} get nodes | grep master | awk '{print $1}')
  MASTER_IP=$(get-ip $name)
}

function detect-nodes {
  read -r -a names <<< $(${KUBECTL} get nodes | grep node | awk '{print $1}')
  i=0
  for name in "${names[@]}"; do
    NODE_IPS[$i]=$(get-ip $name)
    ((i=i+1))
  done
}

# get the ip of the given node
#  $1: the node name
function get-ip {
  echo $(${KUBECTL} get nodes $1 -o json | python -c \
    'import json,sys;print json.load(sys.stdin)["status"]["addresses"][1]["address"]')
}

function ensure-ssh-key {
  kube::log::status "ensure ssh key exists"
  # ensure there is ssh key generated for use
  if [[ ! -f "${HOME}/.ssh/${SSH_KEY_NAME}" ]]; then
    kube::log::status "    generate new ssh key"
    ssh-keygen -f ${HOME}/.ssh/${SSH_KEY_NAME} -N '' >/dev/null
  fi
  # remove any existing ssh key
  if [[ $(nova keypair-list | grep ${SSH_KEY_NAME}) ]]; then
    kube::log::status "    remove existing ssh key"
    nova keypair-delete ${SSH_KEY_NAME}
  fi
  kube::log::status "    upload the new ssh key"
  # upload the newone
  nova keypair-add ${SSH_KEY_NAME} --pub-key "${HOME}/.ssh/${SSH_KEY_NAME}.pub"
}

function decide-image {
  # image setup, we use ubuntu by default, user could use another one by running:
  #   export IMAGE_NAME=xxxx or export IMAGE_ID=xxxx
  kube::log::status "decide image to use"
  IMAGE_NAME=${IMAGE_NAME:-"emi-ubuntu-14.04-server-amd64"}
  if [[ -z $IMAGE_ID ]]; then
    IMAGE_ID=$(nova image-list | grep "$IMAGE_NAME " | awk -F '|' '{print $2}' \
      | tr -d ' ')
  fi
  kube::log::status "    using ${IMAGE_ID}"
}

function boot-nodes {
  # launch nodes
  kube::log::status "boot nodes"
  # master setup, single master is needed
  MASTER_NAME=${MASTER_NAME:-"master"}
  MASTER_UUID=$(nova boot --flavor=8 --image=${IMAGE_ID} ${MASTER_NAME} \
    --key-name ${SSH_KEY_NAME} | grep "| id " | awk -F '|' '{print $3}' \
    | tr -d ' ')
  MASTER_STATUS=""
  kube::log::status "    ${MASTER_NAME}: ${MASTER_UUID}"
  # nodes setup
  for ((i=0; i < NUM_NODES; i++)); do
    NODE_NAMES[$i]="node-$((i+1))"
    NODE_UUIDS[$i]=$(nova boot --flavor=8 --image=${IMAGE_ID} ${NODE_NAMES[$i]} \
      --key-name ${SSH_KEY_NAME} | grep "| id " | awk -F '|' '{print $3}' \
      | tr -d ' ')
    NODE_STATUS[$i]=""
    kube::log::status "    ${NODE_NAMES[$i]}: ${NODE_UUIDS[$i]}"
  done
}

function wait-active {
  # wati for master and all nodes to be in active status
  kube::log::status "waiting all nodes to be active"
  finished=""
  while [[ -z $finished ]]; do
    finished="done"
    if [[ -z $MASTER_STATUS ]]; then
      nova show --minimal ${MASTER_UUID} > "$MASTER_NAME.tmp"
      status=$(cat "$MASTER_NAME.tmp" | grep "| status " \
        | awk -F '|' '{print $3}' | tr -d ' ')
      if [[ $status == 'ACTIVE' ]]; then
        MASTER_STATUS="active"
        MASTER_IP=$(cat "$MASTER_NAME.tmp" | grep "network" \
          | awk -F '|' '{print $3}' | tr -d ' ')
        kube::log::status "    $MASTER_NAME is active: $MASTER_IP"
        ssh-keygen -f "${HOME}/.ssh/known_hosts" -R ${MASTER_IP} &>/dev/null
      else
        finished=""
      fi
      rm -f "$MASTER_NAME.tmp"
    fi
    for ((i=0; i < NUM_NODES; i++)); do
      if [[ -z ${NODE_STATUS[$i]} ]]; then
        nova show --minimal ${NODE_UUIDS[$i]} > "${NODE_NAMES[$i]}.tmp"
        status=$(cat "${NODE_NAMES[$i]}.tmp" | grep "| status " \
          | awk -F '|' '{print $3}' | tr -d ' ')
        if [[ $status == 'ACTIVE' ]]; then
          NODE_STATUS[$i]="active"
          NODE_IPS[$i]=$(cat "${NODE_NAMES[$i]}.tmp" | grep "network" \
            | awk -F '|' '{print $3}' | tr -d ' ')
          kube::log::status "    ${NODE_NAMES[$i]} is active: ${NODE_IPS[$i]}"
          ssh-keygen -f "${HOME}/.ssh/known_hosts" -R ${NODE_IPS[$i]} &>/dev/null
        else
          finished=""
        fi
        rm -f "${NODE_NAMES[$i]}.tmp"
      fi
    done
    sleep 1
  done
}

function deploy-binaries {
  MASTER_BINARIES=(
    cmd/kube-apiserver
    cmd/kube-controller-manager
    plugin/cmd/kube-scheduler
    cmd/kube-proxy
    cmd/kubectl
    cmd/kubelet
  )
  NODE_BINARIES=(
    cmd/kube-proxy
    cmd/kubelet
  )

  # ensure that master is sshable
  ensure-sshable ${MASTER_IP}
  kube::log::status "deploy binaries into master"
  for binary in "${MASTER_BINARIES[@]}"; do
    name=${binary##*/}
    fullpath=$(kube::util::find-binary "${name}")
    if [[ -z ${fullpath} ]]; then
      ${KUBE_ROOT}/hack/build-go.sh "${binary}"
      fullpath=$(kube::util::find-binary "${name}")
    fi
    copy-file $fullpath ${MASTER_IP}
  done

  for node in "${NODE_IPS[@]}"; do
    ensure-sshable ${node}
    kube::log::status "deploy binaries into nodes"
    for binary in "${NODE_BINARIES[@]}"; do
      name=${binary##*/}
      fullpath=$(kube::util::find-binary "${name}")
      if [[ -z ${fullpath} ]]; then
        ${KUBE_ROOT}/hack/build-go.sh "${binary}"
        fullpath=$(kube::util::find-binary "${name}")
      fi
      copy-file $fullpath ${node}
    done
  done
}

# ensure the give ip is sshable
#  $1 the ip
function ensure-sshable {
  maxRetries=20
  for ((i=0; i < maxRetries; i++)); do
    set +o errexit
    timeout 5 nc -z $1 22 &>/dev/null
    if [[ $? -eq 0 ]]; then
      break
    fi
    set -o errexit
    sleep 5
  done
}

# copy-file takes two arguments, the first one is filepath, the second is the
# remote ip
function copy-file {
  scp -i ${HOME}/.ssh/${SSH_KEY_NAME} -o StrictHostKeyChecking=no $1 fedora@$2:~/
}

function master-setup {
  name="master-setup.sh"
  (
    echo "#!/bin/bash"
    echo "cd /tmp"
    echo "export BINDIR=$BINDIR"
    echo "export NODE_IP=${NODE_IPS[0]}"
    echo "export REGISTER_SCHEDULABLE=false"
    echo "export OS_USERNAME=${OS_USERNAME}"
    echo "export OS_TENANT_NAME=${OS_TENANT_NAME}"
    echo "export ADMISSION_CONTROL=${ADMISSION_CONTROL}"
    echo "export AUTHORIZATION_MODE=${AUTHORIZATION_MODE}"
    echo "export RUNTIME_CONFIG=${RUNTIME_CONFIG}"
    echo "export API_SERVER_ARGS=\"${API_SERVER_ARGS}\""
    echo "export KUBELET_ARGS=\"${KUBELET_ARGS}\""
    awk '!/^#/' "${KUBE_ROOT}/cluster/tess-dev/common.sh"
    awk '!/^#/' "${KUBE_ROOT}/cluster/tess-dev/master.sh"
  ) > ${name}
  kube::log::status "execute script on master"
  exec-script ${MASTER_IP} ${name}
  # leave this file here for debug
  # rm -f ${name}
}

function node-setup {
  name="node-setup.sh"
  (
    echo "#!/bin/bash"
    echo "cd /tmp"
    echo "export BINDIR=$BINDIR"
    echo "export MASTER_IP=${MASTER_IP}"
    echo "export KUBELET_ARGS=\"${KUBELET_ARGS}\""
    awk '!/^#/' "${KUBE_ROOT}/cluster/tess-dev/common.sh"
    awk '!/^#/' "${KUBE_ROOT}/cluster/tess-dev/node.sh"
  ) > ${name}
  kube::log::status "execute script on node"
  for node in "${NODE_IPS[@]}"; do
    exec-script ${node} ${name}
  done
  # leave this file here for debug
  # rm -f ${name}
}

function exec-script {
  ssh -i ${HOME}/.ssh/${SSH_KEY_NAME} -o StrictHostKeyChecking=no fedora@$1 \
    "sudo bash -s" < $2
}

function exec-command {
  ssh -i ${HOME}/.ssh/${SSH_KEY_NAME} -o StrictHostKeyChecking=no fedora@$1 \
    "sudo $2"
}

function expose-network {
  exec-command ${MASTER_IP} "${BINDIR}/weave expose &>/dev/null"
  for node in "${NODE_IPS[@]}"; do
    exec-command ${node} "${BINDIR}/weave expose &>/dev/null"
  done
}

function write-kubeconfig {
  kube::log::status "write kubeconfig"
  ${KUBECTL} config set-credentials ${OS_USERNAME} --username=${OS_USERNAME} \
    --password=${OS_PASSWORD}
  ${KUBECTL} config set-cluster tess --server="https://${MASTER_IP}:6443" \
    --insecure-skip-tls-verify=true
  ${KUBECTL} config set-context tess --cluster=tess --user=${OS_USERNAME}
  ${KUBECTL} config use-context tess
}

# create addons pods
function create-addons {
  # create kube-system namespace
  if [[ -z $(${KUBECTL} get ns | grep kube-system) ]]; then
    ${KUBECTL} create --server=http://${MASTER_IP}:8080 ns kube-system
  fi
  if ${ENABLE_KUBE_DNS}; then
    # create dns replication controller and service
    ${KUBECTL} create --server=http://${MASTER_IP}:8080 --validate=false -f \
      ${KUBE_ROOT}/cluster/tess-dev/addons/skydns-rc.yaml
    ${KUBECTL} create --server=http://${MASTER_IP}:8080 --validate=false -f \
      ${KUBE_ROOT}/cluster/tess-dev/addons/skydns-svc.yaml
  fi
}

function prepare-e2e {
  echo "TODO: prepare-e2e"
}

function test-build-release {
  "${KUBE_ROOT}/build/release.sh"
}
