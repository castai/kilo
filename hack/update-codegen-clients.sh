#!/usr/bin/env bash

# Copyright 2021 The KCP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export GOPATH=$(go env GOPATH)

SCRIPT_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
CODEGEN_PKG=${CODEGEN_PKG:-$(cd "${SCRIPT_ROOT}"; go list -f '{{.Dir}}' -m k8s.io/code-generator)}
OPENAPI_PKG=${OPENAPI_PKG:-$(cd "${SCRIPT_ROOT}"; go list -f '{{.Dir}}' -m k8s.io/kube-openapi)}

# TODO: This is hack to allow CI to pass
chmod +x "${CODEGEN_PKG}"/generate-internal-groups.sh

source "${CODEGEN_PKG}/kube_codegen.sh"

kube::codegen::gen_helpers \
  --boilerplate "${SCRIPT_ROOT}"/hack/boilerplate/boilerplate.generatego.txt \
  ./pkg/k8s/apis

kube::codegen::gen_client \
    --with-watch \
    --output-dir "${SCRIPT_ROOT}/pkg/k8s" \
    --output-pkg "github.com/squat/kilo/pkg/k8s" \
    --boilerplate ${SCRIPT_ROOT}/hack/boilerplate/boilerplate.generatego.txt \
    "${SCRIPT_ROOT}/pkg/k8s/apis"

go install "${OPENAPI_PKG}"/cmd/openapi-gen

"$GOPATH"/bin/openapi-gen \
  --go-header-file ./hack/boilerplate/boilerplate.generatego.txt \
  --output-pkg github.com/squat/kilo/pkg/k8s/openapi \
  --output-file zz_generated.openapi.go \
  --output-dir "${SCRIPT_ROOT}/pkg/openapi" \
  github.com/squat/kilo/pkg/k8s/apis/kilo/v1alpha1 \
  k8s.io/apimachinery/pkg/apis/meta/v1 \
  k8s.io/apimachinery/pkg/runtime \
  k8s.io/apimachinery/pkg/version