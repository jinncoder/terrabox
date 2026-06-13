#!/bin/bash

DIR=$(nnn -p -)

if [ -z "${DIR}" ]; then 
  exit 1; 
fi

rm -f "${DIR}"

flameshot gui --path "${DIR}"
