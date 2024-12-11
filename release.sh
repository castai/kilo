#!/bin/bash

# Usage: TAG=0.0.1 ./release.sh

set -e

BASE_IMAGE=alpine:3.12
GOARCH=amd64
DOCKER_REGISTRY=castai/kilo

if [ "$TAG" == "" ]
then
  echo "TAG is not set"
  exit 1
fi

GOOS=linux GOARCH=$GOARCH go build -o ./bin/linux/$GOARCH/kg ./cmd/kg
docker build -t $DOCKER_REGISTRY:$TAG --build-arg FROM=$BASE_IMAGE --build-arg GOARCH=$GOARCH .
docker push $DOCKER_REGISTRY:$TAG
