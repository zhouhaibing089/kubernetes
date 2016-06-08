#!/bin/bash

PREFIX=/home/fedora
BINDIR=${BINDIR:-"/usr/loca/bin"}

# the which command may not be installed
if [[ ! -f /usr/bin/which ]]; then
  yum install -y which &>/dev/null
fi

# check the process id of a given process name
#  $1: process name
# if the process is running, return the process id
function process-id {
  echo $(ps aux | grep $1 | grep -v grep | awk '{print $2}')
}

# ensure that give process is stopped
#  $1: the process name
# this will block until the process is stopped
function ensure-stop {
  pid=$(process-id $1)
  while [[ -n $pid ]]; do
    sleep 1
    pid=$(process-id $1)
  done
}

# setup weave, creat the directories, launch weave
function weave-setup {
  # create weave directories
  if [[ ! -d /opt/cni/bin ]]; then
    mkdir -p /opt/cni/bin
  fi
  if [[ ! -d /etc/cni/net.d ]]; then
    mkdir -p /etc/cni/net.d
  fi

  # start weave
  if [[ -z $(docker ps | grep weave) ]]; then
    echo "start weave"
    ${BINDIR}/weave setup &>/dev/null
    ${BINDIR}/weave launch $@ &>/dev/null
  else
    echo "weave is already running"
  fi
}

# start kubelet
function start-kubelet {
  setup-binary "kubelet"
  ${BINDIR}/kubelet --api-servers=http://${MASTER_IP:-"127.0.0.1"}:8080 \
    --network-plugin=cni \
    --network-plugin-dir=/etc/cni/net.d \
    --register-schedulable=${REGISTER_SCHEDULABLE:-"true"} \
    ${KUBELET_ARGS} \
    --v=10 \
    1>>/var/log/kubelet.log 2>&1 &
}

# start kube-proxy
function start-kube-proxy {
  setup-binary "kube-proxy"
  ${BINDIR}/kube-proxy --master=http://${MASTER_IP:-"127.0.0.1"}:8080 \
    --v=10 \
    1>>/var/log/kube-proxy.log 2>&1 &
}

# setup the necessary binary
function setup-binary {
  name=$1
  pid=$(process-id "${name}")
  if [[ -n ${pid} ]]; then
    echo "${name} is already running, stop it"
    kill ${pid}
    ensure-stop ${name}
    if [[ -f "/var/log/${name}.log" ]]; then
      rm -f "/var/log/${name}.log"
    fi
  fi
  echo "start ${name}"
  cp ${PREFIX}/${name} ${BINDIR}/
}

# install docker
if ! which docker &>/dev/null; then
  echo "install docker"
  curl -fsSL https://get.docker.com/ | sh &>/dev/null
fi

pid=$(process-id docker)
if [[ -n $pid ]]; then
  echo "docker is already running"
else
  echo "start docker"
  systemctl start docker
fi

# install weave
if [[ ! -f ${BINDIR}/weave ]]; then
  echo "install weave"
  curl -L git.io/weave -o ${BINDIR}/weave &>/dev/null
  chmod a+x ${BINDIR}/weave
fi
