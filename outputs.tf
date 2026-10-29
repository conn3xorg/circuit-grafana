output "config_file" {
  description = "Path of grafana.ini on each host."
  value       = local.config_file
}

output "url" {
  description = "URL the circuit checks Grafana on, from each host itself."
  value       = local.url
}
