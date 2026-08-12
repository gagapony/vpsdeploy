#!/bin/bash
set -euo pipefail

resolv_conf=${1:-/etc/resolv.conf}

awk '
    $1 == "nameserver" && NF >= 2 {
        address = $2
        if (index(address, ":") && address !~ /^\[/) {
            address = "[" address "]"
        }
        resolvers = resolvers (resolvers ? " " : "") address
    }
    END {
        if (!resolvers) {
            exit 1
        }
        print resolvers
    }
' "$resolv_conf"
