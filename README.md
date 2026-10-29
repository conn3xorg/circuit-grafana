# circuit-grafana

A Conn3x circuit that installs Grafana OSS from Grafana Labs' own apt and yum repositories, writes `grafana.ini` from a handful of inputs, and provisions your datasources and dashboards from files. It's the self-hosted counterpart to Grafana Cloud: the same Grafana, on a machine you run.

Most of Grafana is easy to install. The part that bites later is the admin password: `admin_password` in `grafana.ini` only counts on the very first start, so changing it afterwards does nothing, quietly. The circuit sets it on the first start, resets it with `grafana cli` whenever you change it, and keeps it out of state. It also pins the release, listens on `127.0.0.1` until you say otherwise, and turns off the usage reporting and update checks Grafana does by default.

## Usage

```hcl
variable "grafana_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "grafana" {
  source = "github.com/conn3xorg/circuit-grafana?ref=v0.1.0"

  hosts                = { dash = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password = var.grafana_admin_password
  http_addr      = "0.0.0.0"
  root_url       = "http://dash.home.arpa:3000/"

  datasources = [{
    name       = "Prometheus"
    type       = "prometheus"
    url        = "http://192.168.1.40:9090"
    is_default = true
  }]
  dashboards_dir = "${path.root}/dashboards"
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_grafana_admin_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it. Then open `http://192.168.1.50:3000` and log in as `admin`.

Grafana listens on `127.0.0.1` unless you set `http_addr`. To reach it from other machines, set `http_addr = "0.0.0.0"` or the host's private address, and put a firewall in front of port 3000, such as [circuit-firewall](https://github.com/conn3xorg/circuit-firewall), or a proxy with TLS, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy). Behind a proxy, set `root_url` to the address people type.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its repository by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.dash : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Datasources

Each entry in `datasources` becomes one datasource in Grafana's main organization, read-only in the UI, since the file is the source of truth. `json_data` takes whatever the datasource type keeps in `jsonData`, such as `{ timeInterval = "15s" }` for Prometheus, or `{ httpMethod = "POST" }`. Give a `uid` when dashboards refer to the datasource by it; otherwise Grafana makes one up.

Take one out of the list and Grafana deletes it on the next start, which the apply triggers. Grafana leaves out the mark that makes this work on datasources it creates on its very first start, so the first apply starts Grafana twice to set it.

There's no `secure_json_data`, for passwords and tokens, yet. Anything put there would land in state.

### Dashboards

Point `dashboards_dir` at a directory of dashboard JSON files, as Grafana exports them. Each `*.json` file in it is copied to `/etc/grafana/dashboards` on every host, and Grafana reads that directory every 30 seconds, so a changed dashboard shows up without a restart, and a removed file takes its dashboard with it. Provisioned dashboards can't be saved from the UI; change the file instead.

### The admin password

`admin_password` reaches the host in `/etc/conn3x/grafana/admin-password`, readable by root and the `grafana` group, and never through state or the plan. `grafana.ini` points at it with `$__file{}`, so Grafana reads it itself on its first start, when it creates the `admin` user.

After that, `grafana.ini` no longer matters for the password. When `admin_password` changes, the apply runs `grafana cli admin reset-admin-password` with the new one on stdin, logs in with it to check, and records its hash. A plan compares that hash with the file rather than trying the password against Grafana, because Grafana locks `admin` out for five minutes after five failed logins. The flip side is that a password changed in Grafana's UI goes unnoticed until `admin_password` changes too.

It has to be at least 8 characters, with no quotes, backslashes or spaces, so it passes through the shell and `curl` unchanged.

## What it does

On each host, in order:

1. Adds Grafana Labs' repository with its signing key: `https://apt.grafana.com`, suite `stable`, on Debian and Ubuntu, and `https://rpm.grafana.com` on the Red Hat family. The key, in `files/grafana.asc`, expires on 22 August 2027. Then installs `curl`, which the checks below use.
2. Installs `grafana` at `grafana_version`. A higher version upgrades it in place.
3. Writes `admin_password` to `/etc/conn3x/grafana/admin-password`, mode `0640`, group `grafana`.
4. Writes `/etc/grafana/grafana.ini` with `[paths]`, `[server]` `http_addr`, `http_port`, `domain` and `root_url`, `[security]` pointing at the password file, `[analytics]` set from `analytics`, and your `settings`. The circuit owns the whole file.
5. Writes your datasources to `/etc/grafana/provisioning/datasources/conn3x.yaml`, with `prune: true`, and a dashboard provider for `/etc/grafana/dashboards` to `/etc/grafana/provisioning/dashboards/conn3x.yaml`, then copies your dashboards there.
6. Restarts Grafana when the package, `grafana.ini` or a provisioning file changed, and starts it at boot. An upgrade on the Red Hat family leaves it stopped, and this starts it again. Then waits, up to two minutes, for `/api/health` to answer.
7. Resets the admin password if `admin_password` is new, and logs in with it to check. The password reaches `curl` on stdin, so it doesn't show in `ps`.

### What it doesn't do

- It runs Grafana on SQLite, Grafana's default, in `/var/lib/grafana`. Pointing `[database]` at PostgreSQL or MySQL through `settings` should work, but hasn't been tested.
- It doesn't set up TLS. Put a proxy in front, or set `[server]` `protocol`, `cert_file` and `cert_key` through `settings` with files you put there yourself.
- It doesn't install plugins, create users, teams, folders or alert rules. Use the [Grafana provider](https://registry.terraform.io/providers/grafana/grafana/latest) against the running server for those.
- It doesn't open a firewall port or touch firewalld or ufw.
- It doesn't install Grafana Enterprise, and it doesn't downgrade.
- Deleting the module leaves Grafana installed and running with the last settings.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `admin_password` | string | Required | Password for Grafana's `admin` user. Ephemeral and sensitive: pass it with `-var` or `TF_VAR_`. At least 8 characters, with no quotes, backslashes or spaces. Changing it resets the password in Grafana. |
| `grafana_version` | string | `"13.3.0"` | Grafana OSS release to install. Raising it upgrades in place. |
| `http_addr` | string | `"127.0.0.1"` | IP address Grafana listens on. `"0.0.0.0"` listens on every address. |
| `http_port` | number | `3000` | Port Grafana listens on. |
| `domain` | string | `null` | `[server]` `domain`. When null, Grafana's default, `localhost`. |
| `root_url` | string | `null` | `[server]` `root_url`, the full URL people reach Grafana at, such as `"https://grafana.example.com/"`. When null, Grafana builds it from `domain` and `http_port`. |
| `analytics` | bool | `false` | Send Grafana Labs anonymous usage statistics, and check grafana.com for new versions of Grafana and its plugins. |
| `settings` | map(map(string)) | `{}` | More `grafana.ini` settings, by section, such as `{ users = { default_theme = "light" }, "auth.anonymous" = { enabled = "true" } }`. Changing them restarts Grafana. `[paths]`, `[analytics]` and the keys the inputs above set aren't allowed. |
| `datasources` | list(object) | `[]` | Datasources to provision. Each has `name`, `type` and `url`, and optionally `access` (default `"proxy"`), `is_default` (default `false`), `uid` and `json_data`. Names must be unique, and only one can be the default. |
| `dashboards_dir` | string | `null` | Local directory of dashboard JSON files to provision on every host. When null, none. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of `grafana.ini` on each host, `/etc/grafana/grafana.ini`. |
| `url` | URL the circuit checks Grafana on, from each host itself, such as `http://127.0.0.1:3000`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with outbound HTTPS to apt.grafana.com or rpm.grafana.com. The droplets it was tested on had 1 GB of memory. amd64 and arm64.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with Grafana 13.3.0. [examples/local](examples/local) was applied to each on arm64, and the second plan had no changes. Then the admin password changed, and the plan after that was clean too. `/api/health` answered, `admin` logged in with the new password, and the provisioned datasource and dashboard were there. On each, renaming the datasource while keeping its `uid` replaced the old one rather than leaving both. CI runs the same checks on amd64. An upgrade from 13.2.5 to 13.3.0 on Rocky Linux 10 came back running, with the password and datasource intact.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both `s-1vcpu-1gb`, the circuit applied with `http_addr = "0.0.0.0"`, `domain` and `root_url`. From another machine, `/api/health` answered, `admin` logged in, and the datasource and dashboard were there. Both came back after a password change and a reboot with Grafana running, the new password working and the second plan clean. On Rocky Linux Grafana runs as `unconfined_service_t`, and the audit log had no denials.

## License

MPL-2.0. See [LICENSE](LICENSE). Grafana itself is AGPL-3.0.
