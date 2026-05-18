output "buckets" {
  description = "Map of consumer name -> bucket name. e.g. { \"tofu-state\" = \"do-nyc3-rke2-demo-tofu-state\", ... }. Consumers read this via direct lookup."
  value = {
    for c, b in digitalocean_spaces_bucket.this : c => b.name
  }
}

output "endpoint" {
  description = "S3-compatible endpoint URL for this region. e.g. \"https://nyc3.digitaloceanspaces.com\". Stable derivation from region — same shape for every DO Spaces region. Consumers use this in their S3 client config."
  value       = "https://${var.region}.digitaloceanspaces.com"
}

output "region" {
  description = "Region slug the buckets live in. Same as var.region; surfaced as an output so downstream consumers don't re-derive it."
  value       = var.region
}

output "bucket_urns" {
  description = "Map of consumer name -> bucket URN. Useful for IAM-like policy attachment in providers that support it; DO Spaces does not currently expose per-bucket policies via Tofu but this output is forward-compatible."
  value = {
    for c, b in digitalocean_spaces_bucket.this : c => b.urn
  }
}
