import boto3
import urllib.parse
import os

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ.get("AWS_ENDPOINT_URL", "http://host.docker.internal:4566"),
)
cloudwatch = boto3.client(
    "cloudwatch",
    endpoint_url=os.environ.get("AWS_ENDPOINT_URL", "http://host.docker.internal:4566"),
)

DEST_BUCKET = os.environ["DEST_BUCKET"]


def put_metric(name, value, dimensions=None, unit="Count"):
    metric_data = {
        "MetricName": name,
        "Value": value,
        "Unit": unit,
    }
    if dimensions:
        metric_data["Dimensions"] = dimensions

    cloudwatch.put_metric_data(
        Namespace="somemathfuncs",
        MetricData=[metric_data],
    )


def handler(event, context):
    for record in event["Records"]:
        src_bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        dimensions = [
            {"Name": "SourceBucket", "Value": src_bucket},
            {"Name": "DestinationBucket", "Value": DEST_BUCKET},
        ]

        try:
            s3.copy_object(
                CopySource={"Bucket": src_bucket, "Key": key},
                Bucket=DEST_BUCKET,
                Key=key,
            )
            put_metric("FilesCopied", 1, dimensions=dimensions)
            print(f"Copied s3://{src_bucket}/{key} -> s3://{DEST_BUCKET}/{key}")
        except Exception:
            put_metric("CopyFailures", 1, dimensions=dimensions)
            raise
