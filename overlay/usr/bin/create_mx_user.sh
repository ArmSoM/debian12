#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

id mxa-manager | useradd --system --no-create-home --shell /usr/sbin/nologin mxa-manager
