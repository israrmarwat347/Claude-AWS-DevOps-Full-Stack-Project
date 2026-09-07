import copy
import hashlib
import json
import threading
import time
from uuid import uuid4

import boto3
from boto3.dynamodb.conditions import Key
from botocore.config import Config
from botocore.exceptions import ClientError
from fastapi import HTTPException

from app.config import Settings


def now():
    return int(time.time())


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def public(item, messages=False):
    fields = ["id", "title", "created_at", "updated_at"]
    result = {key: item[key] for key in fields}
    if messages:
        result["messages"] = json.loads(item["history"])
    return result


class Store:
    """Synchronous persistence operations; call from async routes with asyncio.to_thread."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self.lock = threading.RLock()
        self.memory = {}
        self.table = (
            boto3.resource(
                "dynamodb",
                region_name=settings.aws_region,
                config=Config(
                    retries={"mode": "standard", "max_attempts": 3},
                    connect_timeout=3,
                    read_timeout=5,
                ),
            ).Table(settings.table_name)
            if settings.table_name
            else None
        )

    @staticmethod
    def key(user, cid):
        return {"pk": f"USER#{user}", "sk": f"CONV#{cid}"}

    def rate_limit(self, user, scope, limit):
        minute = now() // 60
        key = {"pk": f"RATE#{scope}#{user}", "sk": str(minute)}
        if self.table:
            try:
                self.table.update_item(
                    Key=key,
                    UpdateExpression="SET expires_at = :ttl ADD requests :one",
                    ConditionExpression="attribute_not_exists(requests) OR requests < :limit",
                    ExpressionAttributeValues={
                        ":ttl": (minute + 2) * 60,
                        ":one": 1,
                        ":limit": limit,
                    },
                )
                return
            except ClientError as exc:
                if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
        else:
            with self.lock:
                self.memory = {k: v for k, v in self.memory.items() if v["expires_at"] > now()}
                k = tuple(key.values())
                record = self.memory.setdefault(k, {"requests": 0, "expires_at": (minute + 2) * 60})
                if record["requests"] < limit:
                    record["requests"] += 1
                    return
        raise HTTPException(
            429, "Request limit reached", headers={"Retry-After": str(60 - now() % 60)}
        )

    def create(self, user):
        cid = str(uuid4())
        item = {
            **self.key(user, cid),
            "id": cid,
            "title": "New conversation",
            "history": "[]",
            "created_at": now(),
            "updated_at": now(),
            "expires_at": now() + self.settings.retention_days * 86400,
        }
        if self.table:
            self.table.put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
        else:
            with self.lock:
                self.memory[(item["pk"], item["sk"])] = item
        return public(item)

    def get(self, user, cid):
        key = self.key(user, cid)
        if self.table:
            item = self.table.get_item(Key=key, ConsistentRead=True).get("Item")
        else:
            with self.lock:
                item = copy.deepcopy(self.memory.get(tuple(key.values())))
        if not item or item["expires_at"] <= now():
            raise HTTPException(404, "Conversation not found")
        return item

    def list(self, user, cursor=None):
        if self.table:
            kwargs = {
                "KeyConditionExpression": Key("pk").eq(f"USER#{user}")
                & Key("sk").begins_with("CONV#"),
                "Limit": 50,
                "ConsistentRead": True,
                "ProjectionExpression": "id, title, created_at, updated_at, expires_at",
            }
            if cursor:
                kwargs["ExclusiveStartKey"] = self.key(user, cursor)
            result = self.table.query(**kwargs)
            items = result["Items"]
            last = result.get("LastEvaluatedKey", {}).get("sk", "")
        else:
            with self.lock:
                items = sorted(
                    [
                        copy.deepcopy(v)
                        for (pk, sk), v in self.memory.items()
                        if pk == f"USER#{user}"
                        and sk.startswith("CONV#")
                        and (not cursor or sk > f"CONV#{cursor}")
                    ],
                    key=lambda v: v["sk"],
                )
            last = items[49]["sk"] if len(items) > 50 else ""
            items = items[:50]
        return {
            "items": [public(i) for i in items if i["expires_at"] > now()],
            "cursor": last.removeprefix("CONV#") or None,
        }

    def begin(self, user, cid, request_id, text):
        key = self.key(user, cid)
        lease = str(uuid4())
        expires = now() + 240  # Longer than the application's entire 120-second operation.
        if self.table:
            try:
                result = self.table.update_item(
                    Key=key,
                    UpdateExpression="SET lease_id = :lease, lease_until = :until",
                    ConditionExpression="attribute_exists(pk) AND expires_at > :now AND "
                    "(attribute_not_exists(lease_until) OR lease_until < :now)",
                    ExpressionAttributeValues={":lease": lease, ":until": expires, ":now": now()},
                    ReturnValues="ALL_NEW",
                )
                item = result["Attributes"]
            except ClientError as exc:
                if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
                self.get(user, cid)  # Distinguish absent/expired items from active leases.
                raise HTTPException(409, "A reply is already being generated") from None
        else:
            with self.lock:
                item = self.get(user, cid)
                if item.get("lease_until", 0) >= now():
                    raise HTTPException(409, "A reply is already being generated")
                item.update(lease_id=lease, lease_until=expires)
                self.memory[tuple(key.values())] = item
        try:
            history = json.loads(item["history"])
            for index, message in enumerate(history):
                if message["role"] == "user" and message.get("request_id") == request_id:
                    if message["content"] != text:
                        raise HTTPException(
                            409, "Request ID was already used for different content"
                        )
                    self.release(user, cid, lease)
                    return None, history, history[index + 1]
            if (
                len(history) >= 80
                or len((item["history"] + text).encode()) > self.settings.max_history_bytes
            ):
                raise HTTPException(413, "Conversation is full; start a new conversation")
            return lease, history, None
        except BaseException:
            self.release(user, cid, lease)
            raise

    def complete(self, user, cid, lease, history, request_id, text, reply, stop_reason, usage):
        assistant = {
            "role": "assistant",
            "content": reply,
            "request_id": request_id,
            "stop_reason": stop_reason,
            "usage": usage,
        }
        history = [*history, {"role": "user", "content": text, "request_id": request_id}, assistant]
        encoded = json.dumps(history, ensure_ascii=False)
        # Well below DynamoDB's 400-KiB limit even for multibyte text and item metadata.
        if len(encoded.encode()) > 280_000:
            raise HTTPException(413, "Conversation storage limit reached")
        values = {
            ":history": encoded,
            ":title": history[0]["content"][:70],
            ":now": now(),
            ":ttl": now() + self.settings.retention_days * 86400,
            ":lease": lease,
        }
        if self.table:
            self.table.update_item(
                Key=self.key(user, cid),
                UpdateExpression="SET history = :history, title = :title, updated_at = :now, "
                "expires_at = :ttl REMOVE lease_id, lease_until",
                ConditionExpression="lease_id = :lease AND lease_until > :now",
                ExpressionAttributeValues=values,
            )
        else:
            with self.lock:
                item = self.get(user, cid)
                if item.get("lease_id") != lease or item["lease_until"] <= now():
                    raise HTTPException(409, "Conversation lease expired")
                item.update(
                    history=encoded,
                    title=values[":title"],
                    updated_at=now(),
                    expires_at=values[":ttl"],
                )
                item.pop("lease_id", None)
                item.pop("lease_until", None)
                self.memory[tuple(self.key(user, cid).values())] = item
        return assistant

    def release(self, user, cid, lease):
        if self.table:
            try:
                self.table.update_item(
                    Key=self.key(user, cid),
                    UpdateExpression="REMOVE lease_id, lease_until",
                    ConditionExpression="lease_id = :lease",
                    ExpressionAttributeValues={":lease": lease},
                )
            except ClientError as exc:
                if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
        else:
            with self.lock:
                item = self.memory.get(tuple(self.key(user, cid).values()))
                if item and item.get("lease_id") == lease:
                    item.pop("lease_id", None)
                    item.pop("lease_until", None)

    def delete(self, user, cid):
        self.get(user, cid)
        if self.table:
            try:
                self.table.delete_item(
                    Key=self.key(user, cid),
                    ConditionExpression="attribute_not_exists(lease_until) OR lease_until < :now",
                    ExpressionAttributeValues={":now": now()},
                )
            except ClientError as exc:
                if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
                raise HTTPException(409, "Wait for the active reply to finish") from None
        else:
            with self.lock:
                item = self.get(user, cid)
                if item.get("lease_until", 0) >= now():
                    raise HTTPException(409, "Wait for the active reply to finish")
                del self.memory[tuple(self.key(user, cid).values())]
