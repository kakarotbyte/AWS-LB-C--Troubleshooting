################################################################################
# EKS Cluster Variables
################################################################################

variable "cluster_name" {
  type    = string
  default = "two"
}
variable "helm_chart_version" {
  type        = string
  default     = "1.5.3"
  description = "ALB Controller Helm chart version."
}