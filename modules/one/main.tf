data "aws_availability_zones" "available" {}

################################################################################
# VPC
################################################################################
module scenario_one_vpc {
    source = "terraform-aws-modules/vpc/aws"
    version = "5.5.2"
    name = var.cluster_name
    cidr = "10.0.0.0/16"
    azs = data.aws_availability_zones.available.names
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
    public_subnets =  ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
    enable_nat_gateway = true
    single_nat_gateway = true
    enable_dns_hostnames = true
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "type" = "public"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "type" = "private"
  }

  tags = {
    "test" = "Demo-VPC"
}
}
################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"

  cluster_name    = var.cluster_name
  cluster_version = "1.28"

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  vpc_id                   = module.scenario_one_vpc.vpc_id
  subnet_ids               = module.scenario_one_vpc.private_subnets
  control_plane_subnet_ids = module.scenario_one_vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    instance_types = ["m5.large"]
  }
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  eks_managed_node_groups = {
    green = {
      min_size     = 1
      max_size     = 1
      desired_size = 1

      instance_types = ["m5.large"]
    }
  }
  # aws-auth configmap
  #manage_aws_auth_configmap = false

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

################################################################################
# new policy doc
################################################################################
 resource "aws_iam_policy" "awslbc_custom_policy" {
   #name        = "awslbc_custom_policy"
   #description = "awslbc_custom_policy"

   # Terraform's "jsonencode" function converts a
   # Terraform expression result to valid JSON syntax.
   #policy = file("modules/one/policy.json")
   policy = file("modules/one/policy-fix.json")
 }


################################################################################
# Load Balancer Role
################################################################################

# module "lb_role" {
# source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
# version = "5.35.0"

# role_name                              = "${var.cluster_name}_eks_lb"
# #attach_load_balancer_controller_policy = true
# role_policy_arns = aws_iam_policy.awslbc_custom_policy.id
# oidc_providers = {
#     main = {
#     provider_arn               = module.eks.oidc_provider_arn
#     namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
#     }

# }
# }
data "aws_iam_policy_document" "AWSLBC_policy_driver_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
  depends_on = [aws_iam_policy.awslbc_custom_policy]
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  assume_role_policy   = data.aws_iam_policy_document.AWSLBC_policy_driver_assume_role_policy.json
}


resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  policy_arn = aws_iam_policy.awslbc_custom_policy.arn
  role       = aws_iam_role.aws_load_balancer_controller.name
}


################################################################################
# Aws Load balancer Controller Service Account
################################################################################
 resource "kubernetes_service_account" "service-account" {
   metadata {
     name      = "aws-load-balancer-controller"
     namespace = "kube-system"
     labels = {
       "app.kubernetes.io/name"      = "aws-load-balancer-controller"
       "app.kubernetes.io/component" = "controller"
     }
     annotations = {
       "eks.amazonaws.com/role-arn"               = aws_iam_role.aws_load_balancer_controller.arn
       "eks.amazonaws.com/sts-regional-endpoints" = "true"
     }
   }
   depends_on = [module.eks]
 }


################################################################################
# Install Load Balancer Controler With Helm
################################################################################

resource "helm_release" "lb" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.helm_chart_version
  namespace  = "kube-system"
  depends_on = [
    kubernetes_service_account.service-account,
    module.eks
  ]

  set {
    name  = "region"
    value = "us-east-1"
  }


  set {
    name  = "vpcId"
    value = module.scenario_one_vpc.vpc_id
  }

  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-load-balancer-controller"
  }
  #set {
  #  name  = "image.tag"
  #  value = "v2.4.7"
  #}

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
}

################################################################################
# Adding sample APP
################################################################################
 resource "kubectl_manifest" "nginx_deploy" {
     yaml_body = <<YAML
 apiVersion: apps/v1
 kind: Deployment
 metadata:
   name: nginx-deployment
   labels:
     app: nginx
 spec:
   replicas: 1
   selector:
     matchLabels:
       app: nginx
   template:
     metadata:
       labels:
         app: nginx
     spec:
       containers:
       - name: nginx
         image: nginx:1.14.2
         ports:
         - containerPort: 80
 YAML
 depends_on = [ module.eks]
 }

# ################################################################################
# # Adding sample service without nodeport
# ################################################################################
 resource "kubectl_manifest" "service_clusterip" {
     yaml_body = <<YAML
 apiVersion: v1
 kind: Service
 metadata:
   annotations:
   labels:
     app: nginx
   name: nginx-clusterip
 spec:
   ports:
   - port: 80
     protocol: TCP
     targetPort: 80
   selector:
     app: nginx
   #type: ClusterIP
   type: NodePort
 YAML
 depends_on = [helm_release.lb, module.eks]
 }

# ################################################################################
# # Adding sample ingress3
# ################################################################################
 resource "kubectl_manifest" "ingress3" {
     yaml_body = <<YAML
 apiVersion: networking.k8s.io/v1
 kind: Ingress
 metadata:
   name: nginx-3
   annotations:
     alb.ingress.kubernetes.io/scheme: internet-facing
     alb.ingress.kubernetes.io/target-type: instance
 spec:
   ingressClassName: alb
   rules:
     - http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx-clusterip
               port:
                 number: 80
 YAML
 depends_on = [kubectl_manifest.service_clusterip, module.eks]
 }

# ################################################################################
# # Adding sample ingress4
# ################################################################################
 resource "kubectl_manifest" "ingress4" {
     yaml_body = <<YAML
 apiVersion: networking.k8s.io/v1
 kind: Ingress
 metadata:
   name: nginx-4
   annotations:
     alb.ingress.kubernetes.io/scheme: internet-facing
     alb.ingress.kubernetes.io/target-type: instance
     alb.ingress.kubernetes.io/manage-backend-security-group-rules: "true"
     #alb.ingress.kubernetes.io/manage-backend-security-group-rules: "false"
     alb.ingress.kubernetes.io/security-groups: ${module.custom_sg.security_group_id}
 spec:
   ingressClassName: alb
   rules:
     - http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx-clusterip
               port:
                 number: 80
 YAML
 depends_on = [kubectl_manifest.service_clusterip,module.custom_sg, module.eks]
 }



module "custom_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "user-service"
  description = "Security group for user-service with custom ports open within VPC, and PostgreSQL publicly open"
  vpc_id      = module.scenario_one_vpc.vpc_id

  ingress_cidr_blocks      = ["0.0.0.0/0"]
  ingress_rules            = ["http-80-tcp"]
    # ingress_with_cidr_blocks = [
    # {
    #   from_port   = 30000
    #   to_port     = 32767
    #   protocol    = "tcp"
    #   description = "User-service ports"
    #   cidr_blocks = "10.10.0.0/16"
    # },
    # ]
}