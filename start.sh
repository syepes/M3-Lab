#!/usr/bin/env bash
set -u
set -eE


function retry() {(
  set +eE
  while true; do
    eval "$@"
    [[ "$?" == 0 ]] && return
    echo -en '\e[1;31m.\e[0m'
    sleep 1
  done
  echo -e '\n'
)}

echo -e "\e[1;31m>>\e[0m Start ETCD and M3DB Nodes"

docker-compose up -d etcd01 etcd02 etcd03
echo -e "\e[1;31m>>\e[0m Wait for ETCD API (etcd01) to be available"
retry '[ "$(curl -sSf localhost:2379/health | jq ".health")" == \"true\" ]'


docker-compose up -d m3db01 m3db02 m3db03
echo -e "\e[1;31m>>\e[0m Wait for coordinator API (m3db01) to be available"
retry '[ "$(curl -sSf localhost:7201/api/v1/namespace | jq ".namespaces | length")" == "0" ]'

function gen_db_instance() {
  local host=$1
  local isolation_group=$2
  echo '{
    "id": "'$host'",
    "isolation_group": "'$isolation_group'",
    "zone": "embedded",
    "weight": 1024,
    "endpoint": "'$host':9000",
    "hostname": "'$host'",
    "port": "9000"
  }'
}

echo -e "\e[1;31m>>\e[0m Adding m3db placement (Topology)"
curl -vsSf -X POST localhost:7201/api/v1/services/m3db/placement/init -d '{
  "num_shards": 32,
  "replication_factor": 2,
  "instances": [
    '"$(gen_db_instance m3db01 rack-1)"',
    '"$(gen_db_instance m3db02 rack-2)"',
    '"$(gen_db_instance m3db03 rack-3)"'
  ]
}' | jq

echo -e "\e[1;31m>>\e[0m Wait until m3db placement is init'd"
retry '[ "$(curl -sSf localhost:7201/api/v1/placement | jq .placement.instances.m3db01.id)" == \"m3db01\" ]'

echo -e "\e[1;31m>>\e[0m Adding non-aggregated namespace: default"
# curl -vsSf -XPOST http://localhost:7201/api/v1/database/namespace/create -d '{"namespaceName": "default", "retentionTime": "1440h"}' | jq
curl -vsSf -X POST localhost:7201/api/v1/services/m3db/namespace -d '{
  "name": "default",
  "options": {
    "bootstrapEnabled": true,
    "flushEnabled": true,
    "writesToCommitLog": true,
    "cleanupEnabled": true,
    "snapshotEnabled": true,
    "repairEnabled": false,
    "retentionOptions": {
      "retentionPeriodDuration": "1440h",
      "blockSizeDuration": "3h",
      "bufferFutureDuration": "10m",
      "bufferPastDuration": "10m",
      "blockDataExpiry": true,
      "blockDataExpiryAfterNotAccessPeriodDuration": "5m"
    },
    "indexOptions": {
      "enabled": true,
      "blockSizeDuration": "6h"
    }
  }
}' | jq .registry.namespaces

echo -e "\e[1;31m>>\e[0m Wait until non-aggregated namespace: default is init'd"
retry '[ "$(curl -sSf localhost:7201/api/v1/namespace | jq .registry.namespaces.default.indexOptions.enabled)" == true ]'

echo -e "\e[1;31m>>\e[0m Adding aggregated namespace: agg_6months_5m"
curl -vsSf -X POST localhost:7201/api/v1/database/namespace/create -d '{
  "namespaceName": "agg_6months_5m",
  "retentionTime": "4320h"
}' | jq .namespace.registry.namespaces.agg_6months_5m

echo -e "\e[1;31m>>\e[0m Adding aggregated namespace: agg_2years_1h"
curl -vsSf -X POST localhost:7201/api/v1/database/namespace/create -d '{
  "namespaceName": "agg_2years_1h",
  "retentionTime": "17520h"
}' | jq .namespace.registry.namespaces.agg_2years_1h

echo -e "\e[1;31m>>\e[0m Wait for all namespaces"
retry '[ "$(curl -sSf localhost:7201/api/v1/namespace | jq ".registry.namespaces | length")" == "3" ]'

echo -e "\e[1;31m>>\e[0m Validating aggregated namespaces"
retry '[ "$(curl -sSf localhost:7201/api/v1/namespace | jq .registry.namespaces.agg_6months_5m.indexOptions.enabled)" == true ]'
retry '[ "$(curl -sSf localhost:7201/api/v1/namespace | jq .registry.namespaces.agg_2years_1h.indexOptions.enabled)" == true ]'

echo -e "\e[1;31m>>\e[0m Waiting until shards are marked as available"
retry '[ "$(curl -sSf localhost:7201/api/v1/placement | grep -c INITIALIZING)" -eq 0 ]'

function gen_aggregator_instance() {
  local host=$1
  local isolation_group=$2
  echo '{
    "id": "'$host':6000",
    "isolation_group": "'$isolation_group'",
    "zone": "embedded",
    "weight": 1024,
    "endpoint": "'$host':6000",
    "hostname": "'$host'",
    "port": "6000"
  }'
}

echo -e "\e[1;31m>>\e[0m Adding m3aggregator placement (Topology)"
curl -vsSf -X POST localhost:7201/api/v1/services/m3aggregator/placement/init -d '{
  "num_shards": 4,
  "replication_factor": 2,
  "instances": [
    '"$(gen_aggregator_instance m3ag01 rack-1)"',
    '"$(gen_aggregator_instance m3ag02 rack-1)"',
    '"$(gen_aggregator_instance m3ag03 rack-2)"',
    '"$(gen_aggregator_instance m3ag04 rack-2)"',
    '"$(gen_aggregator_instance m3ag05 rack-3)"',
    '"$(gen_aggregator_instance m3ag06 rack-3)"'
  ]
}' | jq

echo -e "\e[1;31m>>\e[0m Initializing m3msg topic for m3coordinator ingestion from m3aggregators"
curl -vsSf -X POST localhost:7201/api/v1/topic/init -d '{ "numberOfShards": 4 }' | jq

function gen_coordinator_instance() {
  local host=$1
  local isolation_group=$2
  echo '{
    "id": "'$host'",
    "isolation_group": "'$isolation_group'",
    "zone": "embedded",
    "weight": 1024,
    "endpoint": "'$host':7507",
    "hostname": "'$host'",
    "port": "7507"
  }'
}

echo -e "\e[1;31m>>\e[0m Adding m3coordinator placement (Topology)"
curl -vsSf -X POST localhost:7201/api/v1/services/m3coordinator/placement/init -d '{
  "instances": [
    '"$(gen_coordinator_instance m3cr01 rack-1)"',
    '"$(gen_coordinator_instance m3cr02 rack-2)"',
    '"$(gen_coordinator_instance m3cr03 rack-3)"'
  ]
}' | jq

echo -e "\e[1;31m>>\e[0m Wait until m3coordinator placement is init'd"
retry '[ "$(curl -sSf localhost:7201/api/v1/services/m3coordinator/placement | jq .placement.instances.m3cr01.id)" == \"m3cr01\" ]'

echo -e "\e[1;31m>>\e[0m Adding m3coordinator as a consumer to the topic"
# msgs will be discarded after 600000000000ns = 10mins
curl -vsSf -X POST localhost:7201/api/v1/topic -d '{
  "consumerService": {
    "serviceId": {
      "name": "m3coordinator",
      "environment": "default_env",
      "zone": "embedded"
    },
    "consumptionType": "SHARED",
    "messageTtlNanos": "600000000000"
  }
}' | jq


echo -e "\e[1;31m>>\e[0m Start Coordinator + Aggregator + Query Nodes"
docker-compose up -d m3cr01 m3cr02 m3cr03
docker-compose up -d m3ag01 m3ag02 m3ag03 m3ag04 m3ag05 m3ag06
docker-compose up -d m3qy01

echo -e "\e[1;31m>>\e[0m Start Prometheus + Grafana"
docker-compose up -d