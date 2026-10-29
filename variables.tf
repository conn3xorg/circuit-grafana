variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "grafana_version" {
  type        = string
  default     = "13.3.0"
  description = "Grafana OSS release to install, such as \"13.3.0\". Raising it upgrades Grafana in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.grafana_version))
    error_message = "grafana_version must be a full release, such as \"13.3.0\"."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for Grafana's admin user. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  # Quotes, backslashes and spaces are left out so the password passes
  # through the shell and curl unchanged.
  validation {
    condition     = length(var.admin_password) >= 8 && !can(regex("[\"\\\\'\\s]", var.admin_password))
    error_message = "admin_password must be at least 8 characters, with no quotes, backslashes or spaces."
  }
}

variable "http_addr" {
  type        = string
  default     = "127.0.0.1"
  description = "IP address Grafana listens on, its [server] http_addr. \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.http_addr}/${strcontains(var.http_addr, ":") ? 128 : 32}", 0))
    error_message = "http_addr must be an IPv4 or IPv6 address, such as \"127.0.0.1\", \"10.0.0.5\" or \"0.0.0.0\"."
  }
}

variable "http_port" {
  type        = number
  default     = 3000
  description = "Port Grafana listens on, its [server] http_port."

  validation {
    condition     = var.http_port >= 1 && var.http_port <= 65535 && floor(var.http_port) == var.http_port
    error_message = "http_port must be a port number from 1 to 65535."
  }
}

variable "domain" {
  type        = string
  default     = null
  description = "[server] domain, the name people reach Grafana by, such as \"grafana.example.com\". When null, Grafana's default, localhost."
}

variable "root_url" {
  type        = string
  default     = null
  description = "[server] root_url, the full URL people reach Grafana at, such as \"https://grafana.example.com/\". Set it when Grafana sits behind a proxy. When null, Grafana builds it from domain and http_port."
}

variable "analytics" {
  type        = bool
  default     = false
  description = "Send Grafana Labs anonymous usage statistics and check grafana.com for new versions of Grafana and plugins."
}

variable "settings" {
  type        = map(map(string))
  default     = {}
  description = "More grafana.ini settings, by section, such as { users = { default_theme = \"light\" } }. Changing them restarts Grafana."

  validation {
    condition     = alltrue(flatten([for s, kv in var.settings : [for k, v in kv : can(regex("^[a-z0-9_.]+$", s)) && can(regex("^[A-Za-z0-9_]+$", k)) && !strcontains(v, "\n")]]))
    error_message = "Section names are lowercase words, such as \"users\" or \"auth.anonymous\", keys are words, and values can't contain line breaks."
  }

  validation {
    condition = alltrue(flatten([for s, kv in var.settings : [for k in keys(kv) : !(
      s == "paths" || s == "analytics" ||
      (s == "server" && contains(["http_addr", "http_port", "domain", "root_url"], k)) ||
      (s == "security" && contains(["admin_user", "admin_password"], k))
    )]]))
    error_message = "settings can't set [paths], [analytics], [server] http_addr, http_port, domain or root_url, or [security] admin_user or admin_password. Use the circuit's own inputs."
  }
}

variable "datasources" {
  type = list(object({
    name       = string
    type       = string
    url        = string
    access     = optional(string, "proxy")
    is_default = optional(bool, false)
    uid        = optional(string)
    json_data  = optional(any)
  }))
  default     = []
  description = "Datasources to provision, such as [{ name = \"Prometheus\", type = \"prometheus\", url = \"http://127.0.0.1:9090\", is_default = true }]. One removed from the list is removed from Grafana."

  validation {
    condition     = length(distinct([for d in var.datasources : d.name])) == length(var.datasources)
    error_message = "Each datasource needs its own name."
  }

  validation {
    condition     = length([for d in var.datasources : d if d.is_default]) <= 1
    error_message = "Only one datasource can be the default."
  }
}

variable "dashboards_dir" {
  type        = string
  default     = null
  description = "Local directory of dashboard JSON files, such as \"$${path.root}/dashboards\". Each *.json file is copied to each host and provisioned. When null, no dashboards."
}
