terraform {
  required_providers {
    vastai = {
      source = "berops/vastai"
      version = "~> 0.1.0"
    }
    http = {
         source  = "hashicorp/http"
         version = "~> 3.4"
    }
  }
}
