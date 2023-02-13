#!/usr/bin/env bash

if egrep -q '^\w*ExecStart=' /lib/systemd/system/docker.service \
&& ! sudo egrep -q '^\w*ExecStart=.* -H=tcp://0.0.0.0:2375.*' /lib/systemd/system/docker.service; then
    sudo sed -i -e 's/^\(\w*ExecStart=.*\)$/\1 -H=tcp:\/\/0.0.0.0:2375/' /lib/systemd/system/docker.service;
    sudo systemctl daemon-reload
    sudo service docker restart
    #curl http://localhost:2375/images/json
fi

