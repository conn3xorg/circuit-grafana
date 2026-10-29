variable "port" {
  type    = number
  default = 2222
}

variable "admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "grafana" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  admin_password = var.admin_password
  settings       = { users = { default_theme = "light" } }

  datasources = [{
    name       = "Prometheus"
    type       = "prometheus"
    uid        = "prometheus"
    url        = "http://127.0.0.1:9090"
    is_default = true
    json_data  = { timeInterval = "15s" }
  }]
  dashboards_dir = "${path.root}/dashboards"
}
