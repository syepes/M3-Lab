#!/usr/bin/env bash
set -u
set -eE

docker-compose rm -svf
docker volume prune -f
