#!/bin/bash
#
# Copyright contributors to the Hyperledger Fabric Operator project
#
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
# 	  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

function apply_operator() {

  apply_kustomization config/rbac
  apply_kustomization config/manager

  sleep 2
}

function network_up() {

  init_namespace

  # TODO: remove
  create_image_pull_secret ghcr-pull-secret ghcr.io USERNAME $GITHUB_TOKEN

  apply_operator
  wait_for_deployment fabric-operator

  launch_network_CAs

  apply_network_peers
  apply_network_orderers

  wait_for ibppeer org1-peer1
  wait_for ibppeer org1-peer2
  wait_for ibppeer org2-peer1
  wait_for ibppeer org2-peer2

  wait_for ibporderer org0-orderersnode1
  wait_for ibporderer org0-orderersnode2
  wait_for ibporderer org0-orderersnode3
}

function init_namespace() {
  push_fn "Creating namespace \"$NS\""

  cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-network
EOF

  pop_fn
}

function delete_namespace() {
  push_fn "Deleting namespace \"$NS\""

  kubectl delete namespace $NS --ignore-not-found

  pop_fn
}

function wait_for() {
  local type=$1
  local name=$2

  # wait for the operator to reconcile the CRD with a Deployment
  kubectl -n $NS wait $type $name --for jsonpath='{.status.type}'=Deployed --timeout=60s

  # wait for the deployment to reach Ready
  kubectl -n $NS rollout status deploy $name
}

function launch_network_CAs() {
  push_fn "Launching Fabric CAs"

  apply_kustomization config/cas

  # give the operator a chance to run the first reconciliation on the new resource
  sleep 1

  wait_for ibpca org0-ca
  wait_for ibpca org1-ca
  wait_for ibpca org2-ca

  # load CA TLS certificates into the env, for substitution into the peer and orderer CRDs
  export ORG0_CA_CERT=$(kubectl -n $NS get cm/org0-ca-connection-profile -o json | jq -r .binaryData.\"profile.json\" | base64 -d | jq -r .tls.cert)
  export ORG1_CA_CERT=$(kubectl -n $NS get cm/org1-ca-connection-profile -o json | jq -r .binaryData.\"profile.json\" | base64 -d | jq -r .tls.cert)
  export ORG2_CA_CERT=$(kubectl -n $NS get cm/org2-ca-connection-profile -o json | jq -r .binaryData.\"profile.json\" | base64 -d | jq -r .tls.cert)

  pop_fn
}

function apply_network_peers() {
  push_fn "Launching Fabric Peers"

  apply_kustomization config/peers

  # give the operator a chance to run the first reconciliation on the new resource
  sleep 1

  pop_fn
}

function apply_network_orderers() {
  push_fn "Launching Fabric Orderers"

  apply_kustomization config/orderers

  # give the operator a chance to run the first reconciliation on the new resource
  sleep 1

  pop_fn
}

function stop_services() {
  push_fn "Stopping Fabric Services"

  undo_kustomization config/consoles
  undo_kustomization config/cas
  undo_kustomization config/peers
  undo_kustomization config/orderers

  # give the operator a chance to reconcile the deletion and then shut down the operator.
  sleep 10

  undo_kustomization config/manager

  # scrub any residual bits
  kubectl -n $NS delete deployment --all
  kubectl -n $NS delete pod --all
  kubectl -n $NS delete service --all
  kubectl -n $NS delete configmap --all
  kubectl -n $NS delete ingress --all
  kubectl -n $NS delete secret --all

  pop_fn
}

function network_down() {
  stop_services
  delete_namespace

  rm -rf $PWD/temp
}
