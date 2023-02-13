# Docker Scripts

A collection of scripts for managing docker containers.  These are built for my specific
environment but might be useful for others.

- `backup-container-data.sh` - inspect the docker container for volumes that are bound and
  backup the data to a mounted directory. Default is `/mnt/appdata`
- `container-health-check.sh` - inspect the containers and restart if they are marked as
  unhealthy for a period of time (defined by threshold parameter) restart the container.
