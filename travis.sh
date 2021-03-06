#!/usr/bin/env bash

set -ueo pipefail

dub test

if [ ! -z "${COVERAGE:-}" ]; then
    dub build --build=docs

    dub test -b unittest-cov
    wget https://codecov.io/bash -O codecov.sh
    bash codecov.sh
fi
