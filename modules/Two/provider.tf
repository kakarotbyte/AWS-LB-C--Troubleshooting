provider "kubernetes" {
  host                   = module.eks-2.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks-2.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks-2.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks-2.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks-2.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks-2.cluster_name]
      command     = "aws"
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks-2.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks-2.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks-2.cluster_name]
  }
}