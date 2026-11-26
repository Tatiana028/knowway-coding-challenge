terraform {
  required_version = ">= 1.5.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

provider "docker" {}

resource "docker_network" "edge" {
  name = "edge"
}

resource "docker_network" "internal" {
  name = "internal"
}
 

resource "docker_image" "postgres" {
  name         = "postgres:18.7-trixie"
  keep_locally = true
}

resource "docker_image" "nginx" {
  name         = "nginx:1.30.6-alpine"
  keep_locally = true
}

resource "docker_image" "api" {
  name         = "challenge-api:local"
  keep_locally = true

  build {
    context = "${path.module}/../app"
  }

  triggers = {
    src = sha1(join("", [for f in sort(fileset("${path.module}/../app", "*")) : filesha1("${path.module}/../app/${f}")]))
  }
}

resource "docker_volume" "postgres_data" {
  name = "postgres_data"
}

resource "docker_container" "postgres" {

  volumes {
  volume_name    = docker_volume.postgres_data.name
  container_path = "/var/lib/postgresql"
  }

  networks_advanced {
    name = docker_network.internal.name
  }

  name  = "postgres"
  image = docker_image.postgres.image_id

  env = [
    "POSTGRES_USER=app",
    "POSTGRES_PASSWORD=app",
    "POSTGRES_DB=runs",
  ] 
 
}

resource "docker_container" "api_1" {
  name  = "api-1"
  image = docker_image.api.image_id

  networks_advanced {
    name = docker_network.edge.name
  }

  networks_advanced {
    name = docker_network.internal.name
  }

  env = [
    "DB_HOST=postgres",
    "DB_PORT=5432",
    "DB_NAME=runs",
    "DB_USER=app",
    "DB_PASSWORD=app",
  ] 

  depends_on = [docker_container.postgres]
}

resource "docker_container" "api_2" {
  name  = "api-2"
  image = docker_image.api.image_id

  networks_advanced {
    name = docker_network.edge.name
  }

  networks_advanced {
    name = docker_network.internal.name
  }

  env = [
    "DB_HOST=postgres",
    "DB_PORT=5432",
    "DB_NAME=runs",
    "DB_USER=app",
    "DB_PASSWORD=app",
  ]
 

  depends_on = [docker_container.postgres]
}

resource "docker_container" "proxy" {
  name  = "proxy"
  image = docker_image.nginx.image_id

  networks_advanced {
    name = docker_network.edge.name
  }

  ports {
    internal = 80
    external = 8080
  }

  upload {
    file    = "/etc/nginx/nginx.conf"
    content = file("${path.module}/nginx.conf")
  } 

  # nginx resolves upstream names once at startup, so it must be recreated
  # whenever a replica is.
  lifecycle {
    replace_triggered_by = [docker_container.api_1, docker_container.api_2]
  }
}

output "proxy_url" {
  value = "http://localhost:8080"
}
