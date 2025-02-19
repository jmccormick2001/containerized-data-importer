#!/usr/bin/env bash

#Copyright 2018 The CDI Authors.
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.

set -exo pipefail

readonly MAX_CDI_WAIT_RETRY=30
readonly CDI_WAIT_TIME=10

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
source hack/build/config.sh
source hack/build/common.sh
source cluster-up/hack/common.sh

KUBEVIRTCI_CONFIG_PATH="$(
    cd "$(dirname "$BASH_SOURCE[0]")/../../"
    echo "$(pwd)/_ci-configs"
)"

# functional testing
BASE_PATH=${KUBEVIRTCI_CONFIG_PATH:-$PWD}
KUBECONFIG=${KUBECONFIG:-$BASE_PATH/$KUBEVIRT_PROVIDER/.kubeconfig}
GOCLI=${GOCLI:-${CDI_DIR}/cluster-up/cli.sh}
KUBE_URL=${KUBE_URL:-""}
CDI_NAMESPACE=${CDI_NAMESPACE:-cdi}
SNAPSHOT_SC=${SNAPSHOT_SC:-rook-ceph-block}
BLOCK_SC=${BLOCK_SC:-rook-ceph-block}
# we might want to introduce another storage class and configure Storage Profile correctly
# so on one SC we can test CSI clone and on the other the smartclone
CSICLONE_SC=${CSICLONE_SC:-rook-ceph-block}

OPERATOR_CONTAINER_IMAGE=$(./cluster-up/kubectl.sh get deployment -n $CDI_NAMESPACE cdi-operator -o'custom-columns=spec:spec.template.spec.containers[0].image' --no-headers)
DOCKER_PREFIX=${OPERATOR_CONTAINER_IMAGE%/*}
DOCKER_TAG=${OPERATOR_CONTAINER_IMAGE##*:}

if [ -z "${KUBECTL+x}" ]; then
    kubevirtci_kubectl="${BASE_PATH}/${KUBEVIRT_PROVIDER}/.kubectl"
    if [ -e ${kubevirtci_kubectl} ]; then
        KUBECTL=${kubevirtci_kubectl}
    else
        KUBECTL=$(which kubectl)
    fi
fi

# parsetTestOpts sets 'pkgs' and test_args
parseTestOpts "${@}"

echo $KUBECONFIG
echo $KUBECTL

arg_kubeurl="${KUBE_URL:+-kubeurl=$KUBE_URL}"
arg_namespace="${CDI_NAMESPACE:+-cdi-namespace=$CDI_NAMESPACE}"
arg_kubeconfig="${KUBECONFIG:+-kubeconfig=$KUBECONFIG}"
arg_kubectl="${KUBECTL:+-kubectl-path=$KUBECTL}"
arg_oc="${KUBECTL:+-oc-path=$KUBECTL}"
arg_gocli="${GOCLI:+-gocli-path=$GOCLI}"
arg_sc_snap="${SNAPSHOT_SC:+-snapshot-sc=$SNAPSHOT_SC}"
arg_sc_block="${BLOCK_SC:+-block-sc=$BLOCK_SC}"
arg_sc_csi="${CSICLONE_SC:+-csiclone-sc=$CSICLONE_SC}"
arg_docker_prefix="${DOCKER_PREFIX:+-docker-prefix=$DOCKER_PREFIX}"
arg_docker_tag="${DOCKER_TAG:+-docker-tag=$DOCKER_TAG}"

test_args="${test_args} ${arg_kubeurl} ${arg_namespace} ${arg_kubeconfig} ${arg_kubectl} ${arg_oc} ${arg_gocli} ${arg_sc_snap} ${arg_sc_block} ${arg_sc_csi} ${arg_docker_prefix} ${arg_docker_tag}"

echo 'Wait until all CDI Pods are ready'
retry_counter=0
while [ $retry_counter -lt $MAX_CDI_WAIT_RETRY ] && [ -n "$(./cluster-up/kubectl.sh get pods -n $CDI_NAMESPACE -o'custom-columns=status:status.containerStatuses[*].ready' --no-headers | grep false)" ]; do
    retry_counter=$((retry_counter + 1))
    sleep $CDI_WAIT_TIME
    echo "Checking CDI pods again, count $retry_counter"
    if [ $retry_counter -gt 1 ] && [ "$((retry_counter % 6))" -eq 0 ]; then
        ./cluster-up/kubectl.sh get pods -n $CDI_NAMESPACE
    fi
done

if [ $retry_counter -eq $MAX_CDI_WAIT_RETRY ]; then
    echo "Not all CDI pods became ready"
    ./cluster-up/kubectl.sh get pods -n $CDI_NAMESPACE
    ./cluster-up/kubectl.sh get pods -n $CDI_NAMESPACE -o yaml
    ./cluster-up/kubectl.sh describe pods -n $CDI_NAMESPACE
    exit 1
fi

(
    export TESTS_WORKDIR=${CDI_DIR}/tests
    declare -a ginkgo_args
    ginkgo_args+=(--trace --timeout=8h --v)

    if [[ -n "$CDI_LABEL_FILTER" ]]; then
        ginkgo_args+=(--label-filter="${CDI_LABEL_FILTER}")
    fi

    if [[ -n "$CDI_E2E_SKIP" ]]; then
        ginkgo_args+=(--skip="${CDI_E2E_SKIP}")
    fi

    if [[ "$CDI_E2E_FOCUS" =~ /.+\.go/ ]]; then
        ginkgo_args+=(--focus-file="${CDI_E2E_FOCUS}")
    elif [[ -n "$CDI_E2E_FOCUS" ]]; then
        ginkgo_args+=(--focus="${CDI_E2E_FOCUS}")
    fi

    if [[ -n "$CDI_E2E_FOCUS" || -n "$CDI_E2E_SKIP" ]]; then
        ginkgo_args+=(--nodes=6)
    fi

    ${TESTS_OUT_DIR}/ginkgo "${ginkgo_args[@]}" ${TESTS_OUT_DIR}/tests.test -- ${test_args}
)