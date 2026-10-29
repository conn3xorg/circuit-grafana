# Facts give each host's distribution, which picks Grafana's apt or yum
# repository.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  password_file  = "/etc/conn3x/grafana/admin-password"
  config_file    = "/etc/grafana/grafana.ini"
  dashboards_dir = "/etc/grafana/dashboards"
  dashboards     = var.dashboards_dir == null ? toset([]) : fileset(var.dashboards_dir, "*.json")

  # The circuit's own settings win over the same keys in var.settings,
  # which a validation turns away anyway. [paths] repeats what the
  # package's unit passes on the command line, so grafana cli, which
  # doesn't get those, finds the same database.
  own = {
    paths = {
      data         = "/var/lib/grafana"
      logs         = "/var/log/grafana"
      plugins      = "/var/lib/grafana/plugins"
      provisioning = "/etc/grafana/provisioning"
    }
    server = merge(
      { http_addr = var.http_addr, http_port = tostring(var.http_port) },
      var.domain == null ? {} : { domain = var.domain },
      var.root_url == null ? {} : { root_url = var.root_url },
    )
    security = {
      admin_user     = "admin"
      admin_password = "$__file{${local.password_file}}"
    }
    analytics = {
      reporting_enabled        = tostring(var.analytics)
      check_for_updates        = tostring(var.analytics)
      check_for_plugin_updates = tostring(var.analytics)
    }
  }
  ini_sections = merge(var.settings, { for s, kv in local.own : s => merge(lookup(var.settings, s, {}), kv) })
  ini          = join("\n", [for s, kv in local.ini_sections : join("", concat(["[${s}]\n"], [for k, v in kv : "${k} = ${v}\n"]))])

  # prune drops a provisioned datasource from Grafana once it's gone from
  # the list, which Grafana otherwise keeps.
  datasources = yamlencode({
    apiVersion = 1
    prune      = true
    datasources = [for d in var.datasources : merge(
      { name = d.name, type = d.type, url = d.url, access = d.access, isDefault = d.is_default, editable = false },
      d.uid == null ? {} : { uid = d.uid },
      d.json_data == null ? {} : { jsonData = d.json_data },
    )]
  })

  dashboard_provider = yamlencode({
    apiVersion = 1
    providers = [{
      name                  = "conn3x"
      type                  = "file"
      allowUiUpdates        = false
      updateIntervalSeconds = 30
      options               = { path = local.dashboards_dir }
    }]
  })

  # Where the circuit itself talks to Grafana. 0.0.0.0 and :: listen on
  # loopback too.
  check_host = contains(["0.0.0.0", "::"], var.http_addr) ? "127.0.0.1" : strcontains(var.http_addr, ":") ? "[${var.http_addr}]" : var.http_addr
  url        = "http://${local.check_host}:${var.http_port}"

  # The password reaches curl on stdin, so it never shows in ps.
  login = "printf 'user = \"admin:%s\"\\n' \"$(cat ${local.password_file})\" | curl -sf -K- -o /dev/null ${local.url}/api/user"
}

circuit "grafana" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # One repository serves every release, for Debian and Ubuntu in one apt
  # suite and for the whole Red Hat family in one yum repository. Its
  # signing key expires on 22 August 2027.
  step "repo" {
    repository {
      name   = "grafana"
      url    = local.family[each.key] == "debian" ? "https://apt.grafana.com" : "https://rpm.grafana.com"
      key    = file("${path.module}/files/grafana.asc")
      suites = local.family[each.key] == "debian" ? ["stable"] : null
    }
  }

  # The checks below talk to Grafana's HTTP API with curl.
  step "curl" {
    package {
      name = "curl"
    }
  }

  step "package" {
    package {
      name    = "grafana"
      version = var.grafana_version
    }
  }

  # Grafana reads the password itself on its first start, through
  # $__file{} in grafana.ini, so its group can read it.
  step "password_dir" {
    directory {
      path  = dirname(local.password_file)
      group = "grafana"
      mode  = "0750"
    }
  }

  # The password lands in a file, never in state or the plan.
  step "admin_password" {
    file {
      path       = local.password_file
      content_wo = var.admin_password
      group      = "grafana"
      mode       = "0640"
    }
  }

  step "config" {
    file {
      path    = local.config_file
      content = local.ini
      group   = "grafana"
      mode    = "0640"
    }
  }

  step "datasources" {
    file {
      path    = "/etc/grafana/provisioning/datasources/conn3x.yaml"
      content = local.datasources
      group   = "grafana"
      mode    = "0640"
    }
  }

  step "dashboard_provider" {
    file {
      path    = "/etc/grafana/provisioning/dashboards/conn3x.yaml"
      content = local.dashboard_provider
      group   = "grafana"
      mode    = "0640"
    }
  }

  step "dashboards_dir" {
    directory {
      path  = local.dashboards_dir
      group = "grafana"
      mode  = "0750"
    }
  }

  # Grafana reads the directory every 30 seconds, so a dashboard changes
  # without a restart, and one removed here goes from Grafana too.
  step "dashboards" {
    for_each = local.dashboards
    file {
      path      = "${local.dashboards_dir}/${item.value}"
      content   = file("${var.dashboards_dir}/${item.value}")
      group     = "grafana"
      mode      = "0640"
      on_remove = "delete"
    }
  }

  # Grafana reads grafana.ini and its provisioning files only at start. An
  # upgrade on the Red Hat family leaves it stopped. It runs here rather
  # than in a handler so the steps below find it running. On a first apply
  # it's what starts it, twice: datasources Grafana provisions on its very
  # first start come out without the mark prune looks for, and a second
  # start sets it, so removing them from the list later removes them.
  step "restart" {
    command {
      command = "if [ -e /var/lib/grafana/grafana.db ]; then systemctl restart grafana-server; else systemctl restart grafana-server && for _ in $(seq 60); do curl -sf -o /dev/null ${local.url}/api/health && break; sleep 2; done && sleep 5 && systemctl restart grafana-server; fi"
      triggers = {
        package     = conn3x_package.grafana__package[each.key].revision
        config      = conn3x_file.grafana__config[each.key].revision
        datasources = conn3x_file.grafana__datasources[each.key].revision
        provider    = conn3x_file.grafana__dashboard_provider[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "grafana-server"
      state   = "started"
      enabled = true
    }
  }

  # Grafana takes a few seconds after a start to open its database and
  # answer. The admin step below needs it answering.
  step "ready" {
    command {
      command  = "for _ in $(seq 60); do curl -sf -o /dev/null ${local.url}/api/health && exit 0; sleep 2; done; echo 'Grafana did not answer on ${local.url} within two minutes. See journalctl -u grafana-server.' >&2; exit 1"
      triggers = { restart = conn3x_command.grafana__restart[each.key].revision }
    }
  }

  # grafana.ini's admin_password only counts on Grafana's first start, when
  # it creates the admin user. After that, a new admin_password would leave
  # the two disagreeing, so the apply resets it with grafana cli and logs in
  # to check. It records the password's hash rather than probing with a
  # login on each plan: Grafana locks admin out for five minutes after five
  # failed logins.
  step "admin" {
    command {
      command  = "grafana cli --homepath /usr/share/grafana --config ${local.config_file} admin reset-admin-password --password-from-stdin < ${local.password_file} >/dev/null && { ${local.login} || { echo 'Grafana did not accept admin_password after resetting it. If failed logins locked admin out, wait five minutes and apply again.' >&2; exit 1; }; } && sha256sum ${local.password_file} > ${local.password_file}.applied"
      unless   = "sha256sum -c --status ${local.password_file}.applied"
      triggers = { password = conn3x_file.grafana__admin_password[each.key].revision }
    }
  }
}
