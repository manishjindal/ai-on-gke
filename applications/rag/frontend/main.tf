# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
data "google_project" "project" {
  project_id = var.project_id
}

locals {
  instance_connection_name = format("%s:%s:%s", var.project_id, var.region, var.cloudsql_instance)
}

# IAP Section: Creates the GKE components
module "iap_auth" {
  count  = var.add_auth ? 1 : 0
  source = "../../../modules/iap"

  project_id               = var.project_id
  namespace                = var.namespace
  app_name                 = "frontend"
  brand                    = var.brand
  k8s_ingress_name         = var.k8s_ingress_name
  k8s_managed_cert_name    = var.k8s_managed_cert_name
  k8s_iap_secret_name      = var.k8s_iap_secret_name
  k8s_backend_config_name  = var.k8s_backend_config_name
  k8s_backend_service_name = var.k8s_backend_service_name
  k8s_backend_service_port = var.k8s_backend_service_port
  client_id                = var.client_id
  client_secret            = var.client_secret
  url_domain_addr          = var.url_domain_addr
  url_domain_name          = var.url_domain_name
  depends_on = [
    kubernetes_service.rag_frontend_service
  ]
}

module "frontend-workload-identity" {
  source              = "terraform-google-modules/kubernetes-engine/google//modules/workload-identity"
  version             = "30.0.0" # Pinning to a previous version as current version (30.1.0) showed inconsitent behaviour with workload identity service accounts
  use_existing_gcp_sa = !var.create_service_account
  name                = var.google_service_account
  namespace           = var.namespace
  project_id          = var.project_id
  roles               = ["roles/cloudsql.client", "roles/dlp.admin"]
}

resource "kubernetes_service" "rag_frontend_service" {
  metadata {
    name      = "rag-frontend"
    namespace = var.namespace
  }
  spec {
    selector = {
      app = "rag-frontend"
    }
    session_affinity = var.add_auth ? "None" : "ClientIP"
    port {
      port        = 8080
      target_port = 8080
    }

    type = var.add_auth ? "NodePort" : "ClusterIP"
  }
}

resource "kubernetes_deployment" "rag_frontend_deployment" {
  metadata {
    name      = "rag-frontend"
    namespace = var.namespace
    labels = {
      app = "rag-frontend"
    }
  }

  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "rag-frontend"
      }
    }

    template {
      metadata {
        labels = {
          app = "rag-frontend"
        }
      }

      spec {
        service_account_name = var.google_service_account
        container {
          image = "us-central1-docker.pkg.dev/ai-on-gke/rag-on-gke/frontend@sha256:e2dd85e92f42e3684455a316dee5f98f61f1f3fba80b9368bd6f48d5e2e3475e"
          name  = "rag-frontend"

          port {
            container_port = 8080
          }

          env {
            name  = "PROJECT_ID"
            value = "projects/${var.project_id}"
          }

          env {
            name  = "INSTANCE_CONNECTION_NAME"
            value = local.instance_connection_name
          }

          env {
            name  = "INFERENCE_ENDPOINT"
            value = var.inference_service_endpoint
          }

          env {
            name  = "TABLE_NAME"
            value = var.dataset_embeddings_table_name
          }

          env {
            name = "DB_USER"
            value_from {
              secret_key_ref {
                name = var.db_secret_name
                key  = "username"
              }
            }
          }

          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.db_secret_name
                key  = "password"
              }
            }
          }

          env {
            name = "DB_NAME"
            value_from {
              secret_key_ref {
                name = var.db_secret_name
                key  = "database"
              }
            }
          }

          resources {
            limits = {
              cpu               = "3"
              memory            = "3Gi"
              ephemeral-storage = "5Gi"
            }
            requests = {
              cpu               = "3"
              memory            = "3Gi"
              ephemeral-storage = "5Gi"
            }
          }
        }

        container {
          image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.8.0"
          name  = "cloud-sql-proxy"

          args = [
            "--structured-logs",
            local.instance_connection_name,
          ]

          security_context {
            run_as_non_root = true
          }

          resources {
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }
            requests = {
              cpu    = "1"
              memory = "2Gi"
            }
          }
        }
      }
    }
  }
}

data "kubernetes_service" "frontend-ingress" {
  metadata {
    name      = var.k8s_ingress_name
    namespace = var.namespace
  }
  depends_on = [module.iap_auth]
}
