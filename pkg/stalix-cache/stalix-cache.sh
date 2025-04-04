#!/usr/bin/env bash

set -x
set -e

export PATH=/run/current-system/sw/bin/

cd /var/stalix/work

if [ ! -d ix ]; then
  git clone https://github.com/stal-ix/ix
fi

cd ix

git pull

./ix recache /var/stalix/cache
