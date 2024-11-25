export GO111MODULE=on
.PHONY: push container clean container-name container-latest push-latest fmt lint test unit gomodtidy generate crds codegen manifest manfest-latest manifest-annotate manifest manfest-latest manifest-annotate release e2e

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
IMAGE ?= squat/$(PROJECT)
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
LD_FLAGS := -buildvcs=false -ldflags '-X $(PKG)/pkg/version.Version=$(VERSION)'
SRC := $(shell find . -type f -name '*.go')
GO_FILES ?= $$(find . -name '*.go')
GO_PKGS ?= $$(go list ./...)

CONTROLLER_GEN_BINARY := bin/controller-gen
CLIENT_GEN_BINARY := bin/client-gen
DOCS_GEN_BINARY := bin/docs-gen
DEEPCOPY_GEN_BINARY := bin/deepcopy-gen
INFORMER_GEN_BINARY := bin/informer-gen
LISTER_GEN_BINARY := bin/lister-gen
STATICCHECK_BINARY := bin/staticcheck
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

build: $(BINS)

build-%:
	@$(MAKE) --no-print-directory OS=$(word 1,$(subst -, ,$*)) ARCH=$(word 2,$(subst -, ,$*)) build

container-latest-%:
	@$(MAKE) --no-print-directory ARCH=$* container-latest

container-%:
	@$(MAKE) --no-print-directory ARCH=$* container

push-latest-%:
	@$(MAKE) --no-print-directory ARCH=$* push-latest

push-%:
	@$(MAKE) --no-print-directory ARCH=$* push

all-build: $(addprefix build-$(OS)-, $(ALL_ARCH))

all-container: $(addprefix container-, $(ALL_ARCH))

all-push: $(addprefix push-, $(ALL_ARCH))

all-container-latest: $(addprefix container-latest-, $(ALL_ARCH))

all-push-latest: $(addprefix push-latest-, $(ALL_ARCH))

generate: codegen crds

$(BINS): $(SRC) go.mod
	@mkdir -p bin/$(word 2,$(subst /, ,$@))/$(word 3,$(subst /, ,$@))
	@echo "building: $@"
	@docker run --rm \
	    -u $$(id -u):$$(id -g) \
	    -v $$(pwd):/$(PROJECT) \
	    -w /$(PROJECT) \
	    $(BUILD_IMAGE) \
	    /bin/sh -c " \
	        GOARCH=$(word 3,$(subst /, ,$@)) \
	        GOOS=$(word 2,$(subst /, ,$@)) \
	        GOCACHE=/$(PROJECT)/.cache \
		CGO_ENABLED=0 \
		go build -o $@ \
		    $(LD_FLAGS) \
		    ./cmd/$(@F)/... \
	    "

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

$(KIND_BINARY):
	curl -Lo $@ https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-$(ARCH)
	chmod +x $@

$(KUBECTL_BINARY):
	curl -Lo $@ https://dl.k8s.io/release/v1.31.0/bin/linux/$(ARCH)/kubectl
	chmod +x $@

$(BASH_UNIT):
	curl -Lo $@ https://raw.githubusercontent.com/pgrange/bash_unit/v2.3.1/bash_unit
	chmod +x $@

e2e: container $(KIND_BINARY) $(KUBECTL_BINARY) $(BASH_UNIT) bin/$(OS)/$(ARCH)/kgctl
	KILO_IMAGE=$(IMAGE):$(ARCH)-$(VERSION) KIND_BINARY=$(KIND_BINARY) KUBECTL_BINARY=$(KUBECTL_BINARY) KGCTL_BINARY=$(shell pwd)/bin/$(OS)/$(ARCH)/kgctl $(BASH_UNIT) $(BASH_UNIT_FLAGS) ./e2e/setup.sh ./e2e/multi-cluster.sh ./e2e/handlers.sh ./e2e/kgctl.sh ./e2e/teardown.sh

tmp/help.txt: bin/$(OS)/$(ARCH)/kg
	mkdir -p tmp
	bin//$(OS)/$(ARCH)/kg --help 2>&1 | head -n -1 > $@

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

container: .container-$(ARCH)-$(VERSION) container-name
.container-$(ARCH)-$(VERSION): bin/linux/$(ARCH)/kg bin/linux/$(ARCH)/kgctl Dockerfile
	@i=0; for a in $(ALL_ARCH); do [ "$$a" = $(ARCH) ] && break; i=$$((i+1)); done; \
	ia=""; iv=""; \
	j=0; for a in $(DOCKER_ARCH); do \
	    [ "$$i" -eq "$$j" ] && ia=$$(echo "$$a" | awk '{print $$1}') && iv=$$(echo "$$a" | awk '{print $$2}') && break; j=$$((j+1)); \
	done; \
	SHA=$$(docker manifest inspect $(BASE_IMAGE) | jq '.manifests[] | select(.platform.architecture == "'$$ia'") | if .platform | has("variant") then select(.platform.variant == "'$$iv'") else . end | .digest' -r); \
	docker build -t $(IMAGE):$(ARCH)-$(VERSION) --build-arg FROM=$(BASE_IMAGE)@$$SHA --build-arg GOARCH=$(ARCH) .
	@docker images -q $(IMAGE):$(ARCH)-$(VERSION) > $@

container-latest: .container-$(ARCH)-$(VERSION)
	@docker tag $(IMAGE):$(ARCH)-$(VERSION) $(FULLY_QUALIFIED_IMAGE):$(ARCH)-latest
	@echo "container: $(IMAGE):$(ARCH)-latest"

container-name:
	@echo "container: $(IMAGE):$(ARCH)-$(VERSION)"

manifest: .manifest-$(VERSION) manifest-name
.manifest-$(VERSION): Dockerfile $(addprefix push-, $(ALL_ARCH))
	@docker manifest create --amend $(FULLY_QUALIFIED_IMAGE):$(VERSION) $(addsuffix -$(VERSION), $(addprefix $(FULLY_QUALIFIED_IMAGE):, $(ALL_ARCH)))
	@$(MAKE) --no-print-directory manifest-annotate-$(VERSION)
	@docker manifest push $(FULLY_QUALIFIED_IMAGE):$(VERSION) > $@

manifest-latest: Dockerfile $(addprefix push-latest-, $(ALL_ARCH))
	@docker manifest rm $(FULLY_QUALIFIED_IMAGE):latest || echo no old manifest
	@docker manifest create --amend $(FULLY_QUALIFIED_IMAGE):latest $(addsuffix -latest, $(addprefix $(FULLY_QUALIFIED_IMAGE):, $(ALL_ARCH)))
	@$(MAKE) --no-print-directory manifest-annotate-latest
	@docker manifest push $(FULLY_QUALIFIED_IMAGE):latest
	@echo "manifest: $(IMAGE):latest"

manifest-annotate: manifest-annotate-$(VERSION)

manifest-annotate-%:
	@i=0; \
	for a in $(ALL_ARCH); do \
	    annotate=; \
	    j=0; for da in $(DOCKER_ARCH); do \
		if [ "$$j" -eq "$$i" ] && [ -n "$$da" ]; then \
		    annotate="docker manifest annotate $(FULLY_QUALIFIED_IMAGE):$* $(FULLY_QUALIFIED_IMAGE):$$a-$* --os linux --arch"; \
		    k=0; for ea in $$da; do \
			[ "$$k" = 0 ] && annotate="$$annotate $$ea"; \
			[ "$$k" != 0 ] && annotate="$$annotate --variant $$ea"; \
			k=$$((k+1)); \
		    done; \
		    $$annotate; \
		fi; \
		j=$$((j+1)); \
	    done; \
	    i=$$((i+1)); \
	done

manifest-name:
	@echo "manifest: $(IMAGE):$(VERSION)"

push: .push-$(ARCH)-$(VERSION) push-name
.push-$(ARCH)-$(VERSION): .container-$(ARCH)-$(VERSION)
ifneq ($(REGISTRY),index.docker.io)
	@docker tag $(IMAGE):$(ARCH)-$(VERSION) $(FULLY_QUALIFIED_IMAGE):$(ARCH)-$(VERSION)
endif
	@docker push $(FULLY_QUALIFIED_IMAGE):$(ARCH)-$(VERSION)
	@docker images -q $(IMAGE):$(ARCH)-$(VERSION) > $@

push-latest: container-latest
	@docker push $(FULLY_QUALIFIED_IMAGE):$(ARCH)-latest
	@echo "pushed: $(IMAGE):$(ARCH)-latest"

push-name:
	@echo "pushed: $(IMAGE):$(ARCH)-$(VERSION)"

release: $(RELEASE_BINS)
$(RELEASE_BINS):
	@make OS=$(word 2,$(subst -, ,$(@F))) ARCH=$(word 3,$(subst -, ,$(@F)))
	mkdir -p $(@D)
	cp bin/$(word 2,$(subst -, ,$(@F)))/$(word 3,$(subst -, ,$(@F)))/kgctl $@

clean: container-clean bin-clean
	rm -rf .cache

container-clean:
	rm -rf .container-* .manifest-* .push-*

bin-clean:
	rm -rf bin

gomodtidy:
	go mod tidy

$(CONTROLLER_GEN_BINARY):
	go build  -o $@ sigs.k8s.io/controller-tools/cmd/controller-gen

$(CLIENT_GEN_BINARY):
	go build  -o $@ k8s.io/code-generator/cmd/client-gen

$(DEEPCOPY_GEN_BINARY):
	go build  -o $@ k8s.io/code-generator/cmd/deepcopy-gen

$(INFORMER_GEN_BINARY):
	go build  -o $@ k8s.io/code-generator/cmd/informer-gen

$(LISTER_GEN_BINARY):
	go build  -o $@ k8s.io/code-generator/cmd/lister-gen

$(DOCS_GEN_BINARY): cmd/docs-gen/main.go
	go build  -o $@ ./cmd/docs-gen

$(STATICCHECK_BINARY):
	go build  -o $@ honnef.co/go/tools/cmd/staticcheck

$(EMBEDMD_BINARY):
	go build  -o $@ github.com/campoy/embedmd
