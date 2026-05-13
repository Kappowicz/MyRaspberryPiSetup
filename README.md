# MyRaspberryPiSetup (in progress)
my raspberry pi 5 4gb 'pihole + air pollution sensor + simple website' setup configuration, all configuration in podman with use of Quadlet which makes all of it restart after power outage etc

Updating pihole:
ssh on raspberrypi
podman pull docker.io/pihole/pihole:latest
systemctl --user restart pihole.service
