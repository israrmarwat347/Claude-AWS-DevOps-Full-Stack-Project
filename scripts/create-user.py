#!/usr/bin/env python3
"""Create a Cognito user with hidden password input and no invitation email."""

import argparse
import getpass

import boto3

parser = argparse.ArgumentParser()
parser.add_argument("--pool-id", required=True)
parser.add_argument("--region", default="eu-west-1")
args = parser.parse_args()
email = input("Sign-in email: ").strip()
password = getpass.getpass("Temporary password (14+ chars, upper/lower/digit/symbol): ")
confirmation = getpass.getpass("Confirm temporary password: ")
if password != confirmation or len(password) < 14:
    parser.error("Passwords must match and be at least 14 characters.")
client = boto3.client("cognito-idp", region_name=args.region)
try:
    client.admin_create_user(
        UserPoolId=args.pool_id,
        Username=email,
        MessageAction="SUPPRESS",
        UserAttributes=[
            {"Name": "email", "Value": email},
            {"Name": "email_verified", "Value": "true"},
        ],
    )
except client.exceptions.UsernameExistsException:
    parser.error("User already exists; reset their password through the Cognito console.")
client.admin_set_user_password(
    UserPoolId=args.pool_id, Username=email, Password=password, Permanent=False
)
print("User created without sending an invitation. Sign in and change the temporary password.")
