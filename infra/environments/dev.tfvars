environment           = "dev"
vpc_cidr              = "10.20.0.0/16"
task_count            = 1
max_tasks             = 3
high_availability_nat = false
enable_waf            = false
retention_days        = 7
# TODO: Supply domain_name, route53_zone_id and runtime_boundary_arn through GitHub environment variables.
# TODO: The workflow supplies immutable image_uri and release_sha.
