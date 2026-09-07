import boto3
import pytest
from moto import mock_aws

from app.config import Settings
from app.store import Store


@pytest.fixture(params=["memory", "dynamodb"])
def store(request, monkeypatch):
    settings = Settings(local_auth=True, mock_claude=True)
    if request.param == "memory":
        yield Store(settings)
        return
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    with mock_aws():
        boto3.client("dynamodb", region_name=settings.aws_region).create_table(
            TableName="test-chat",
            BillingMode="PAY_PER_REQUEST",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
        )
        settings.table_name = "test-chat"
        yield Store(settings)
