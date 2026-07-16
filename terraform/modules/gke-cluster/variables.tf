variable "project_id" { type = string }
variable "region" { type = string }
variable "cluster_name" { type = string }

variable "node_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 3
}
