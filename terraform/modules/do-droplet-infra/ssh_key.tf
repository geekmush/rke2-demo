resource "digitalocean_ssh_key" "operator" {
  name       = "${var.project_name}-operator"
  public_key = var.ssh_pubkey
}
