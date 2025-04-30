#!/usr/bin/env bash

export PATH=/run/current-system/sw/bin/
export AWS_PAGER=""

function set_self_ip4() {
  MYIP4="$(curl -4 ifconfig.co)"
  echo "IPv4: $MYIP4"

  TIMESTAMP="$(date +%s%N)"
  TMPFILE=/tmp/zoneupdate-${TIMESTAMP}.json
  cat <<EOT >"$TMPFILE"
{
    "Comment":"Update v4 address",
    "Changes":[{
        "Action":"UPSERT",
        "ResourceRecordSet":{
            "Name": "$1",
            "Type":"A",
            "TTL": 30,
            "ResourceRecords":[{
                "Value": "${MYIP4}"
            }]
        }
    }]
}
EOT

  @aws@ route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch file://$TMPFILE
  rm "$TMPFILE"
}

function set_self_ip6() {
  MYIP6="$(curl -6 ifconfig.co)"
  echo "IPv6: $MYIP6"

  TIMESTAMP="$(date +%s%N)"
  TMPFILE=/tmp/zoneupdate-${TIMESTAMP}.json
  cat <<EOT >"$TMPFILE"
{
    "Comment":"Update v6 address",
    "Changes":[{
        "Action":"UPSERT",
        "ResourceRecordSet":{
            "Name": "$1",
            "Type":"AAAA",
            "TTL": 30,
            "ResourceRecords":[{
                "Value": "${MYIP6}"
            }]
        }
    }]
}
EOT

  @aws@ route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch file://$TMPFILE
  rm "$TMPFILE"
}

source "$1"

set_self_ip4 "$2"

if [[ -n "$3" ]]; then
  set_self_ip6 "$3"
fi
