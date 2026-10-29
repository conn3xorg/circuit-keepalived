output "config_file" {
  description = "Path of the keepalived config the circuit writes on each host."
  value       = local.config
}

output "priorities" {
  description = "Each host's VRRP priority."
  value       = local.priority
}

output "master" {
  description = "The host with the highest priority, which holds the floating addresses while it's up."
  value       = [for name in local.names : name if local.priority[name] == max(values(local.priority)...)][0]
}
