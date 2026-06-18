#!/usr/bin/env bash
echo DONE\; press Y to exit
while read -rsn1 k; do [[ $k == [yY] ]] && break; done
