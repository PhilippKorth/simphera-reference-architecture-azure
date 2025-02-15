resource "azurerm_resource_group" "postgres" {
  name     = "${var.name}-postgresql"
  location = var.location
  tags     = var.tags
}

resource "random_password" "postgresql-password" {
  length           = 16
  special          = true
  override_special = "!#$%&*-_+:?"
  min_lower        = 2
  min_upper        = 2
  min_special      = 2
  min_numeric      = 2
}

resource "azurerm_key_vault_secret" "postgresql-credentials" {
  name         = "${var.name}-postgresqlcredentials"
  value        = jsonencode({ "postgresql_username" : "dbuser", "postgresql_password" : random_password.postgresql-password.result })
  key_vault_id = var.keyVaultId
}

locals {
  servername          = "${var.name}-postgresql"
  postgresql_username = jsondecode(azurerm_key_vault_secret.postgresql-credentials.value)["postgresql_username"]
  postgresql_password = jsondecode(azurerm_key_vault_secret.postgresql-credentials.value)["postgresql_password"]
  fulllogin           = "${local.postgresql_username}@${local.servername}"
  basic_tier          = split("_", var.postgresqlSkuName)[0] == "B"
  gp_tier             = split("_", var.postgresqlSkuName)[0] == "GP"
}

resource "azurerm_postgresql_server" "postgresql-server" {
  name                = local.servername
  location            = azurerm_resource_group.postgres.location
  resource_group_name = azurerm_resource_group.postgres.name

  administrator_login          = local.postgresql_username
  administrator_login_password = local.postgresql_password

  sku_name   = var.postgresqlSkuName
  version    = var.postgresqlVersion
  storage_mb = var.postgresqlStorage

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = false

  public_network_access_enabled    = local.basic_tier ? true : false
  ssl_enforcement_enabled          = false
  ssl_minimal_tls_version_enforced = "TLSEnforcementDisabled"


  tags = var.tags

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

output "postgresql_server_hostname" {
  value     = azurerm_postgresql_server.postgresql-server.fqdn
  sensitive = false
}

output "postgresql_server_username" {
  value     = local.fulllogin
  sensitive = true
}

resource "azurerm_private_endpoint" "postgresql-endpoint" {
  count               = local.gp_tier ? 1 : 0
  name                = "postgresql-endpoint"
  location            = azurerm_postgresql_server.postgresql-server.location
  resource_group_name = azurerm_postgresql_server.postgresql-server.resource_group_name
  subnet_id           = var.paasServicesSubnetId

  private_dns_zone_group {
    name                 = "postgresql-zone-group"
    private_dns_zone_ids = [var.postgresqlPrivatelinkDnsZoneId]
  }

  private_service_connection {
    name                           = "simphera-postgresql"
    private_connection_resource_id = azurerm_postgresql_server.postgresql-server.id
    is_manual_connection           = false
    subresource_names              = ["postgresqlServer"]
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

resource "azurerm_postgresql_firewall_rule" "postgresql-firewall" {
  count               = local.basic_tier ? 1 : 0
  name                = "aks_cluster"
  resource_group_name = azurerm_resource_group.postgres.name
  server_name         = azurerm_postgresql_server.postgresql-server.name
  start_ip_address    = var.aksIpAddress
  end_ip_address      = var.aksIpAddress
}

resource "azurerm_postgresql_database" "keycloak" {
  name                = "keycloak"
  resource_group_name = azurerm_postgresql_server.postgresql-server.resource_group_name
  server_name         = azurerm_postgresql_server.postgresql-server.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}

resource "azurerm_postgresql_database" "simphera" {
  name                = "simphera"
  resource_group_name = azurerm_postgresql_server.postgresql-server.resource_group_name
  server_name         = azurerm_postgresql_server.postgresql-server.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}

output "secretname" {
  value = azurerm_key_vault_secret.postgresql-credentials.name
}
