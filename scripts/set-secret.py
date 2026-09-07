#!/usr/bin/env python3
"""Upload a key without putting it in argv, environment variables or Terraform state."""

import argparse
import getpass
import json

import boto3

parser = argparse.ArgumentParser()
parser.add_argument("--secret-id", required=True)
parser.add_argument("--region", default="eu-west-1")
args = parser.parse_args()
value = getpass.getpass("Anthropic API key (hidden): ").strip()
if not value or not value.startswith("sk-ant-"):
    parser.error("Enter an Anthropic API key beginning sk-ant-.")
boto3.client("secretsmanager", region_name=args.region).put_secret_value(
    SecretId=args.secret_id, SecretString=json.dumps({"ANTHROPIC_API_KEY": value})
)
print("Secret updated. Running tasks refresh the key within five minutes.")
