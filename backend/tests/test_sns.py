import json
import boto3
from botocore.stub import Stubber

import sns


def test_sns_publish_without_topic_returns_none(monkeypatch):
    monkeypatch.delenv("SNS_TOPIC_ARN", raising=False)
    monkeypatch.setattr(sns, "get_topic_arn", lambda: "")

    result = sns.publish_event("pin.liked", {"pin_id": "123"})
    assert result is None


def test_sns_publish_with_topic_calls_boto3(monkeypatch):
    test_arn = "arn:aws:sns:us-east-1:123456789012:pinwatch-events"
    monkeypatch.setattr(sns, "get_topic_arn", lambda: test_arn)

    client = boto3.client(
        "sns",
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )

    with Stubber(client) as stubber:
        stubber.add_response(
            "publish",
            {"MessageId": "msg-999"},
        )

        monkeypatch.setattr(sns, "sns_client", lambda: client)

        res = sns.publish_event("pin.liked", {"pin_id": "123"}, subject="PinWatch: Like")
        assert res is not None
        assert res["MessageId"] == "msg-999"
        stubber.assert_no_pending_responses()

