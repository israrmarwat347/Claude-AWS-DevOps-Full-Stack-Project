environment           = "prod"
vpc_cidr              = "10.40.0.0/16"
task_count            = 2
max_tasks             = 6
task_cpu              = 512
task_memory           = 1024
high_availability_nat = true
enable_waf            = true
retention_days        = 30
# TODO: Require production environment reviewers before enabling this workflow.
