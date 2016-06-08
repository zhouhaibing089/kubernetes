#!/bin/bash

weave-setup ${MASTER_IP}

start-kubelet
start-kube-proxy
