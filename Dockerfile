from docker.io/library/golang:1.24.0 as builder
WORKDIR /workspace


# # Install prerequisites
# run apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
#     build-essential \
#     cmake \
#     curl \
#     git \
#     wget \


# RUN \
#     --mount=type=bind,src=./,target=/workspace,relabel=shared,ro=true \
#     --mount=type=bind,src=./charts,target=/workspace/charts,relabel=shared,ro=false,idmap=true \
#     --mount=type=bind,src=./src,target=/workspace/src,relabel=shared,ro=false,idmap=true \
#     --mount=type=cache,target=/workspace/hack  \
#     --mount=type=cache,target=/workspace/out  \
#     make build-helm-charts

RUN \
    --mount=type=bind,src=./,target=/workspace,rw,bind-propagation=rshared \
    --mount=type=cache,target=/workspace/hack  \
    --mount=type=cache,target=/workspace/out  \
    make RAMNDOM=$(echo $RANDOM) build-helm-charts

