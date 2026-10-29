# Local example

Applies circuit-grafana to a throwaway Rocky Linux 10 container with systemd, with one Prometheus datasource and the dashboard in [dashboards](dashboards). You need Conn3x and Podman.

Grafana's systemd unit sandboxes itself, which only works in a privileged container, so this is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
export TF_VAR_admin_password='choose-a-password'
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To look at the result:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  "curl -s -u 'admin:$TF_VAR_admin_password' http://127.0.0.1:3000/api/datasources"
```

Nothing listens on 9090 in the container, so the datasource is there but has nothing to query. Change `TF_VAR_admin_password` and apply again to see the password reset.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
