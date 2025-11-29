# random passwords / names

resource "random_string" "bucket_name_gen" {
  length  = 6
  special = false
  upper   = false
}

resource "random_password" "db_root_password" {
  length  = 24
  special = true
}

resource "random_password" "db_wp_user_password" {
  length  = 16
  special = false
  upper   = true # включаем заглавные буквы
  lower   = true # включаем маленькие буквы
}

locals {
  network_name   = "${var.name_prefix}-network"
  subnet_name    = "${var.name_prefix}-subnet"
  bucket_name    = "wp-bucket-${random_string.bucket_name_gen.result}"
  db_port_string = tostring(var.db_port)
}

# VPC network + subnet
resource "yandex_vpc_network" "this" {
  name = local.network_name
}

resource "yandex_vpc_subnet" "private" {
  name           = local.subnet_name
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = var.subnets[keys(var.subnets)[0]]
}

resource "yandex_vpc_security_group" "external_sg" {
  name        = "external-sg"
  network_id  = yandex_vpc_network.this.id
  description = "Allow any external traffic"
  egress {
    description    = "all"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "gate_sg" {
  name        = "gate-sg"
  network_id  = yandex_vpc_network.this.id
  description = "Allow web ingress"
  ingress {
    description    = "HTTP"
    protocol       = "TCP"
    port           = 8080
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description    = "HTTPS"
    protocol       = "TCP"
    port           = 4444
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description    = "SSH"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "db_sg" {
  name        = "db-sg"
  network_id  = yandex_vpc_network.this.id
  description = "Allow DB ingress"
  ingress {
    description = "MySQL from VPC"
    protocol    = "TCP"
    port        = var.db_port
    # ограничиваем подсетью
    v4_cidr_blocks = [yandex_vpc_subnet.private.v4_cidr_blocks[0]] # используем CIDR подсети
  }
}

# Service account for object storage + static key
resource "yandex_iam_service_account" "storage_sa" {
  name        = "wp-storage-sa"
  description = "SA for WP object storage access"
  folder_id   = var.folder_id
}

resource "yandex_iam_service_account_static_access_key" "storage_sa_key" {
  service_account_id = yandex_iam_service_account.storage_sa.id
  description        = "static access key for object storage"
  # secret_key will be available only on create
}

# Grant storage.admin role to the service account at folder scope (so it can manage the bucket)
resource "yandex_resourcemanager_folder_iam_binding" "folder_storage_admin" {
  folder_id = var.folder_id
  role      = "storage.admin"

  members = [
    "serviceAccount:${yandex_iam_service_account.storage_sa.id}"
  ]
}

resource "yandex_storage_bucket" "wp_bucket" {
  bucket = local.bucket_name

  folder_id = var.folder_id

  anonymous_access_flags {
    read = true  # Доступ к объектам без авторизации
    list = false # Запрет листинга
  }

  # Разрешить автоматическое уничтожение вместе с объектами
  force_destroy = true

  # Теги (рекомендуется)
  tags = {
    project = "wordpress"
  }
}

# Managed MySQL cluster (single-host minimal example)
resource "yandex_mdb_mysql_cluster" "mysql" {
  name        = "wp-mysql"
  folder_id   = var.folder_id
  environment = "PRESTABLE"
  version     = "8.0"

  network_id = yandex_vpc_network.this.id
  resources {
    resource_preset_id = "s2.micro"
    disk_size          = 20
    disk_type_id       = "network-ssd"
  }

  # hosts block: один хост в указанной подсети/зоне
  host {
    subnet_id = yandex_vpc_subnet.private.id
    zone      = var.zone
  }

  # security groups (разрешить доступ к кластеру)
  security_group_ids = [yandex_vpc_security_group.db_sg.id, yandex_vpc_security_group.external_sg.id]
}

# Create a DB (database) in the cluster
resource "yandex_mdb_mysql_database" "wp_db" {
  cluster_id = yandex_mdb_mysql_cluster.mysql.id
  name       = "wordpress_db"
}

# Create DB user for WordPress
resource "yandex_mdb_mysql_user" "wp_user" {
  cluster_id = yandex_mdb_mysql_cluster.mysql.id
  name       = "wp_user"
  password   = random_password.db_wp_user_password.result
  # grant access to the created DB
  permission {
    database_name = yandex_mdb_mysql_database.wp_db.name
    roles         = ["ALL"]
  }
}

# Compute instance to host WordPress (cloud-init will configure WP and use DB credentials)
data "yandex_compute_image" "ubuntu" {
  family = var.instance_image_family
}

resource "yandex_compute_instance" "wp_vm" {
  name        = var.instance_name
  platform_id = var.instance_platform
  zone        = var.zone

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 40
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.private.id
    nat       = true
    security_group_ids = [
      yandex_vpc_security_group.external_sg.id,
      yandex_vpc_security_group.gate_sg.id
    ]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.public_ssh}"
    user-data = templatefile("${path.module}/cloud-init.tpl", {
      wp_db_host = yandex_mdb_mysql_cluster.mysql.host[0].fqdn
      wp_db_name = yandex_mdb_mysql_database.wp_db.name
      wp_db_user = yandex_mdb_mysql_user.wp_user.name
      wp_db_pass = random_password.db_wp_user_password.result
      wp_db_port = local.db_port_string
    })
  }
}


# Outputs
output "wp_vm_public_ip" {
  value = yandex_compute_instance.wp_vm.network_interface[0].nat_ip_address
}

output "wp_db_password" {
  value     = random_password.db_wp_user_password.result
  sensitive = true
}

