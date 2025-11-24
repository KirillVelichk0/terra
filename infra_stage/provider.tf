# Объявление провайдера
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 1.00"
}

provider "yandex" {
  zone      = "ru-central1-a"
  folder_id = "b1ga78ois40ili82tpjc"
}

provider "random" {
}
