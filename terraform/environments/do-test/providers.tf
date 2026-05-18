provider "digitalocean" {
  token = var.do_token

  # Spaces (S3-compatible object storage) credentials. Sourced from
  # SOPS-encrypted secrets.enc.tfvars via the Makefile wrapper. Empty
  # by default -- droplet operations don't need them. Required when
  # object_store_provider == "do_spaces" instantiates the spaces module.
  # See openspec/changes/enable-s3-object-store/.
  spaces_access_id  = var.object_store_access_key
  spaces_secret_key = var.object_store_secret_key
}
