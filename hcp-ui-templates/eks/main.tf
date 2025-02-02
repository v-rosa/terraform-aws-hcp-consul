locals {
  vpc_region          = "{{ .VPCRegion }}"
  hvn_region          = "{{ .HVNRegion }}"
  cluster_id          = "{{ .ClusterID }}"
  hvn_id              = "{{ .ClusterID }}-hvn"
  install_demo_app    = true
  install_eks_cluster = true
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.43"
    }

    hcp = {
      source  = "hashicorp/hcp"
      version = ">= 0.18.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.14.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.7.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
  }

}

provider "aws" {
  region = local.vpc_region
}

provider "helm" {
  kubernetes {
    host                   = local.install_eks_cluster ? data.aws_eks_cluster.cluster[0].endpoint : ""
    cluster_ca_certificate = local.install_eks_cluster ? base64decode(data.aws_eks_cluster.cluster[0].certificate_authority.0.data) : ""
    token                  = local.install_eks_cluster ? data.aws_eks_cluster_auth.cluster[0].token : ""
  }
}

provider "kubernetes" {
  host                   = local.install_eks_cluster ? data.aws_eks_cluster.cluster[0].endpoint : ""
  cluster_ca_certificate = local.install_eks_cluster ? base64decode(data.aws_eks_cluster.cluster[0].certificate_authority.0.data) : ""
  token                  = local.install_eks_cluster ? data.aws_eks_cluster_auth.cluster[0].token : ""
}

provider "kubectl" {
  host                   = local.install_eks_cluster ? data.aws_eks_cluster.cluster[0].endpoint : ""
  cluster_ca_certificate = local.install_eks_cluster ? base64decode(data.aws_eks_cluster.cluster[0].certificate_authority.0.data) : ""
  token                  = local.install_eks_cluster ? data.aws_eks_cluster_auth.cluster[0].token : ""
  load_config_file       = false
}
data "aws_availability_zones" "available" {
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.78.0"

  name                 = "${local.cluster_id}-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  public_subnets       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets      = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

data "aws_eks_cluster" "cluster" {
  count = local.install_eks_cluster ? 1 : 0
  name  = module.eks[0].cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  count = local.install_eks_cluster ? 1 : 0
  name  = module.eks[0].cluster_id
}

module "eks" {
  count                  = local.install_eks_cluster ? 1 : 0
  source                 = "terraform-aws-modules/eks/aws"
  version                = "17.24.0"
  kubeconfig_api_version = "client.authentication.k8s.io/v1beta1"

  cluster_name    = "${local.cluster_id}-eks"
  cluster_version = "1.21"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  manage_aws_auth = false

  node_groups = {
    application = {
      name_prefix    = "hashicups"
      instance_types = ["t3a.medium"]

      desired_capacity = 3
      max_capacity     = 3
      min_capacity     = 3
    }
  }
}

# The HVN created in HCP
resource "hcp_hvn" "main" {
  hvn_id         = local.hvn_id
  cloud_provider = "aws"
  region         = local.hvn_region
  cidr_block     = "172.25.32.0/20"
}

# Note: Uncomment the below module to setup peering for connecting to a private HCP Consul cluster
# module "aws_hcp_consul" {
#   source  = "hashicorp/hcp-consul/aws"
#   version = "~> 0.9.0"
#
#   hvn                = hcp_hvn.main
#   vpc_id             = module.vpc.vpc_id
#   subnet_ids         = module.vpc.private_subnets
#   route_table_ids    = module.vpc.private_route_table_ids
#   security_group_ids = local.install_eks_cluster ? [module.eks[0].cluster_primary_security_group_id] : [""]
# }

resource "hcp_consul_cluster" "main" {
  cluster_id         = local.cluster_id
  hvn_id             = hcp_hvn.main.hvn_id
  public_endpoint    = true
  tier               = "development"
  min_consul_version = "v1.14.0"
}

resource "hcp_consul_cluster_root_token" "token" {
  cluster_id = hcp_consul_cluster.main.id
}

module "eks_consul_client" {
  source  = "hashicorp/hcp-consul/aws//modules/hcp-eks-client"
  version = "~> 0.9.0"

  boostrap_acl_token = hcp_consul_cluster_root_token.token.secret_id
  cluster_id         = hcp_consul_cluster.main.cluster_id
  # strip out `https://` from the public url
  consul_hosts     = tolist([substr(hcp_consul_cluster.main.consul_public_endpoint_url, 8, -1)])
  consul_version   = hcp_consul_cluster.main.consul_version
  datacenter       = hcp_consul_cluster.main.datacenter
  k8s_api_endpoint = local.install_eks_cluster ? module.eks[0].cluster_endpoint : ""

  # The EKS node group will fail to create if the clients are
  # created at the same time. This forces the client to wait until
  # the node group is successfully created.
  depends_on = [module.eks]
}

module "demo_app" {
  count   = local.install_demo_app ? 1 : 0
  source  = "hashicorp/hcp-consul/aws//modules/k8s-demo-app"
  version = "~> 0.9.0"

  depends_on = [module.eks_consul_client]
}
output "consul_root_token" {
  value     = hcp_consul_cluster_root_token.token.secret_id
  sensitive = true
}

output "consul_url" {
  value = hcp_consul_cluster.main.public_endpoint ? (
    hcp_consul_cluster.main.consul_public_endpoint_url
    ) : (
    hcp_consul_cluster.main.consul_private_endpoint_url
  )
}

output "kubeconfig_filename" {
  value = abspath(one(module.eks[*].kubeconfig_filename))
}

output "helm_values_filename" {
  value = abspath(module.eks_consul_client.helm_values_file)
}

output "hashicups_url" {
  value = "${one(module.demo_app[*].hashicups_url)}:8080"
}

output "next_steps" {
  value = "HashiCups Application will be ready in ~2 minutes. Use 'terraform output consul_root_token' to retrieve the root token."
}

output "howto_connect" {
  value = <<EOF
  ${local.install_demo_app ? "The demo app, HashiCups, Has been installed for you and its components registered in Consul." : ""}
  ${local.install_demo_app ? "To access HashiCups navigate to: ${one(module.demo_app[*].hashicups_url)}:8080" : ""}

  To access Consul from your local client run:
  export CONSUL_HTTP_ADDR="${hcp_consul_cluster.main.consul_public_endpoint_url}"
  export CONSUL_HTTP_TOKEN=$(terraform output -raw consul_root_token)
  
  ${local.install_eks_cluster ? "You can access your provisioned eks cluster by first running following command" : ""}
  ${local.install_eks_cluster ? "export KUBECONFIG=$(terraform output -raw kubeconfig_filename)" : ""}    

  Consul has been installed in the default namespace. To explore what has been installed run:
  
  kubectl get pods

  EOF
}
