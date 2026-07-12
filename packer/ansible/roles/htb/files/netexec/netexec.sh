#!/usr/bin/env bash

docker run --rm -it --network host \
    -v /tmp/:/tmp/ \
    netexec:local $@