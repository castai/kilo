export GO111MODULE=on
.PHONY: push container clean push-latest fmt lint test unit gomodtidy generate crds codegen e2e

OS ?= $(shell go env GOOS)
ARCH ?= $(shell go env GOARCH)
ALL_ARCH := amd64 arm arm64
DOCKER_ARCH := "amd64" "arm v7" "arm64 v8"
ifeq ($(OS),linux)
    BINS := bin/$(OS)/$(ARCH)/kg bin/$(OS)/$(ARCH)/kgctl
else
    BINS := bin/$(OS)/$(ARCH)/kgctl
endif
RELEASE_BINS := $(addprefix bin/release/kgctl-, $(addprefix linux-, $(ALL_ARCH)) darwin-amd64 darwin-arm64 windows-amd64)
PROJECT := kilo
PKG := github.com/squat/$(PROJECT)
REGISTRY ?= index.docker.io
IMAGE ?= castai/$(PROJECT)
FULLY_QUALIFIED_IMAGE := $(REGISTRY)/$(IMAGE)

TAG := $(shell git describe --abbrev=0 --tags HEAD 2>/dev/null)
COMMIT := $(shell git rev-parse HEAD)
VERSION := $(COMMIT)
ifneq ($(TAG),)
    ifeq ($(COMMIT), $(shell git rev-list -n1 $(TAG)))
        VERSION := $(TAG)
    endif
endif
DIRTY := $(shell test -z "$$(git diff --shortstat 2>/dev/null)" || echo -dirty)
VERSION := $(VERSION)$(DIRTY)

LDFLAGS := -X $(PKG)/pkg/version.Version=$(VERSION)
SRC := $(shell find . -type f -name '*.go')
GO_FILES ?= $$(find . -name '*.go')
GO_PKGS ?= $$(go list ./...)

STATICCHECK_BINARY := bin/staticcheck
DOCS_GEN_BINARY := bin/docs-gen
EMBEDMD_BINARY := bin/embedmd
KIND_BINARY := $(shell pwd)/bin/kind
KUBECTL_BINARY := $(shell pwd)/bin/kubectl
BASH_UNIT := $(shell pwd)/bin/bash_unit
BASH_UNIT_FLAGS :=

BUILD_IMAGE ?= golang:1.23.0
BASE_IMAGE ?= alpine:3.20

GO_INSTALL = ./hack/go-install.sh
TOOLS_DIR=hack/tools
ROOT_DIR=$(abspath .)
TOOLS_GOBIN_DIR := $(abspath $(TOOLS_DIR))
GOBIN_DIR=$(abspath ./bin)
PATH := $(GOBIN_DIR):$(TOOLS_GOBIN_DIR):$(PATH)

# Detect the path used for the install target
ifeq (,$(shell go env GOBIN))
INSTALL_GOBIN=$(shell go env GOPATH)/bin
else
INSTALL_GOBIN=$(shell go env GOBIN)
endif

CONTROLLER_GEN_VER := v0.16.1
CONTROLLER_GEN_BIN := controller-gen
CONTROLLER_GEN := $(TOOLS_DIR)/$(CONTROLLER_GEN_BIN)-$(CONTROLLER_GEN_VER)
export CONTROLLER_GEN # so hack scripts can use it

YAML_PATCH_VER ?= v0.0.11
YAML_PATCH_BIN := yaml-patch
YAML_PATCH := $(TOOLS_DIR)/$(YAML_PATCH_BIN)-$(YAML_PATCH_VER)
export YAML_PATCH # so hack scripts can use it

OPENSHIFT_GOIMPORTS_VER := c72f1dc2e3aacfa00aece3391d938c9bc734e791
OPENSHIFT_GOIMPORTS_BIN := openshift-goimports
OPENSHIFT_GOIMPORTS := $(TOOLS_DIR)/$(OPENSHIFT_GOIMPORTS_BIN)-$(OPENSHIFT_GOIMPORTS_VER)
export OPENSHIFT_GOIMPORTS # so hack scripts can use i

$(CONTROLLER_GEN):
	GOBIN=$(TOOLS_GOBIN_DIR) $(GO_INSTALL) sigs.k8s.io/controller-tools/cmd/controller-gen $(CONTROLLER_GEN_BIN) $(CONTROLLER_GEN_VER)

$(YAML_PATCH):
	GOBIN=$(TOOLS_GOBIN_DIR) $(GO_INSTALL) github.com/pivotal-cf/yaml-patch/cmd/yaml-patch $(YAML_PATCH_BIN) $(YAML_PATCH_VER)

$(OPENSHIFT_GOIMPORTS):
	GOBIN=$(TOOLS_GOBIN_DIR) $(GO_INSTALL) github.com/openshift-eng/openshift-goimports $(OPENSHIFT_GOIMPORTS_BIN) $(OPENSHIFT_GOIMPORTS_VER)

crds: $(CONTROLLER_GEN) $(YAML_PATCH) $(OPENSHIFT_GOIMPORTS) ## Generate crds
	./hack/update-codegen-crds.sh
.PHONY: crds

tools: $(CONTROLLER_GEN) $(YAML_PATCH) ## Install tools
.PHONY: tool

codegen: crds ## Generate all
	go mod download
	./hack/update-codegen-clients.sh
	$(MAKE) imports
.PHONY: codegen

.PHONY: imports
imports: $(OPENSHIFT_GOIMPORTS)
	$(OPENSHIFT_GOIMPORTS) -m github.com/squat/kilo


tools: $(CONTROLLER_GEN) $(YAML_PATCH) $(OPENSHIFT_GOIMPORTS)  ## Install tools
.PHONY: tools

build: WHAT ?= ./cmd/...
build: mkdirbin
	GOOS=$(OS) GOARCH=$(ARCH) CGO_ENABLED=0 go build $(BUILDFLAGS) -ldflags="$(LDFLAGS)" -o bin $(WHAT)
.PHONY: build

goreleaser:
	LDFLAGS=$(LDFLAGS) goreleaser

ldflags:
	@echo $(LDFLAGS)

generate: codegen crds

fmt:
	@echo $(GO_PKGS)
	gofmt -w -s $(GO_FILES)

lint: $(STATICCHECK_BINARY)
	@echo 'go vet $(GO_PKGS)'
	@vet_res=$$(GO111MODULE=on go vet $(GO_PKGS) 2>&1); if [ -n "$$vet_res" ]; then \
		echo ""; \
		echo "Go vet found issues. Please check the reported issues"; \
		echo "and fix them if necessary before submitting the code for review:"; \
		echo "$$vet_res"; \
		exit 1; \
	fi
	@echo '$(STATICCHECK_BINARY) $(GO_PKGS)'
	@lint_res=$$($(STATICCHECK_BINARY) $(GO_PKGS)); if [ -n "$$lint_res" ]; then \
		echo ""; \
		echo "Staticcheck found style issues. Please check the reported issues"; \
		echo "and fix them if necessary before submitting the code for review:"; \
		echo "$$lint_res"; \
		exit 1; \
	fi
	@echo 'gofmt -d -s $(GO_FILES)'
	@fmt_res=$$(gofmt -d -s $(GO_FILES)); if [ -n "$$fmt_res" ]; then \
		echo ""; \
		echo "Gofmt found style issues. Please check the reported issues"; \
		echo "and fix them if necessary before submitting the code for review:"; \
		echo "$$fmt_res"; \
		exit 1; \
	fi
	
unit:
	go test --race ./...

test: lint unit e2e

mkdirbin:
	mkdir -p bin/

$(KIND_BINARY):
	curl -Lo $@ https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-$(ARCH)
	chmod +x $@

$(KUBECTL_BINARY):
	curl -Lo $@ https://dl.k8s.io/release/v1.31.0/bin/linux/$(ARCH)/kubectl
	chmod +x $@

$(BASH_UNIT):
	curl -Lo $@ https://raw.githubusercontent.com/pgrange/bash_unit/v2.3.1/bash_unit
	chmod +x $@

e2e: mkdirbin container $(KIND_BINARY) $(KUBECTL_BINARY) $(BASH_UNIT) build
	KILO_IMAGE=$(IMAGE):$(ARCH)-$(VERSION) KIND_BINARY=$(KIND_BINARY) KUBECTL_BINARY=$(KUBECTL_BINARY) KGCTL_BINARY=$(shell pwd)/bin/kgctl $(BASH_UNIT) $(BASH_UNIT_FLAGS) ./e2e/setup.sh ./e2e/multi-cluster.sh ./e2e/handlers.sh ./e2e/kgctl.sh ./e2e/teardown.sh

tmp/help.txt: build
	mkdir -p tmp
	bin/kg --help 2>&1 | head -n -1 > $@

docs/kg.md: $(EMBEDMD_BINARY) tmp/help.txt
	$(EMBEDMD_BINARY) -w $@

website/docs/README.md: README.md
	rm -rf website/static/img/graphs
	find docs  -type f -name '*.md' | xargs -I{} sh -c 'cat $(@D)/$$(basename {} .md) > website/{}'
	find docs  -type f -name '*.md' | xargs -I{} sh -c 'cat {} >> website/{}'
	cat $(@D)/$$(basename $@ .md) > $@
	cat README.md >> $@
	cp -r docs/graphs website/static/img/
	sed -i 's/\.\/docs\///g' $@
	find $(@D)  -type f -name '*.md' | xargs -I{} sed -i 's/\.\/\(.\+\.\(svg\|png\)\)/\/img\/\1/g' {}
	sed -i 's/graphs\//\/img\/graphs\//g' $@
	# The next line is a workaround until mdx, docusaurus' markdown parser, can parse links with preceding brackets.
	sed -i  's/\[\]\(\[.*\](.*)\)/\&#91;\&#93;\1/g' website/docs/api.md

website/build/index.html: website/docs/README.md docs/api.md
	yarn --cwd website install
	yarn --cwd website build

container:
	docker build -t $(FULLY_QUALIFIED_IMAGE):latest -f Dockerfile .

container-linux:
	FULLY_QUALIFIED_IMAGE=$(FULLY_QUALIFIED_IMAGE-
	OS=linux ARCH=amd64 make container

clean: bin-clean
	rm -rf .cache

bin-clean:
	rm -rf bin

gomodtidy:
	go mod tidy

$(DOCS_GEN_BINARY): cmd/docs-gen/main.go
	go build  -o $@ ./cmd/docs-gen

$(STATICCHECK_BINARY):
	go build  -o $@ honnef.co/go/tools/cmd/staticcheck

$(EMBEDMD_BINARY):
	go build  -o $@ github.com/campoy/embedmd
