"""
Lambda Handler — Slow Downstream (Chaos Scenario 3)
Simulates a downstream dependency with an artificial delay that exceeds
the Lambda timeout, causing the DevOps Agent to investigate timeout errors.

When CHAOS_MODE=true:
  - Sleeps for ARTIFICIAL_DELAY_MS milliseconds before responding
  - Since Lambda timeout is 3s and delay is 4500ms → guaranteed timeout
  - CloudWatch logs will show: Task timed out after 3.00 seconds
  - X-Ray traces will show: latency spike in this function

What the agent should identify:
  1. Lambda function consistently timing out (Errors metric spike)
  2. Duration metric approaching/exceeding configured timeout
  3. X-Ray traces showing where the latency originates
  4. Recommendation: increase timeout OR fix the underlying slow operation
"""

import json
import os
import time
import logging
import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    chaos_mode = os.environ.get("CHAOS_MODE", "false").lower() == "true"
    delay_ms = int(os.environ.get("ARTIFICIAL_DELAY_MS", "0"))
    environment = os.environ.get("ENVIRONMENT", "unknown")

    request_id = context.aws_request_id
    function_name = context.function_name
    remaining_ms = context.get_remaining_time_in_millis()

    logger.info(json.dumps({
        "event": "invocation_start",
        "request_id": request_id,
        "function": function_name,
        "environment": environment,
        "chaos_mode": chaos_mode,
        "configured_delay_ms": delay_ms,
        "remaining_time_ms": remaining_ms,
        "timestamp": datetime.datetime.utcnow().isoformat()
    }))

    if chaos_mode and delay_ms > 0:
        logger.warning(json.dumps({
            "event": "chaos_delay_start",
            "delay_ms": delay_ms,
            "timeout_ms": remaining_ms,
            "will_timeout": delay_ms > remaining_ms,
            "message": f"Artificial delay of {delay_ms}ms — Lambda timeout is ~{remaining_ms}ms"
        }))

        # Sleep in chunks so CloudWatch shows partial execution before timeout
        chunk_ms = 500
        elapsed = 0

        while elapsed < delay_ms:
            time.sleep(chunk_ms / 1000)
            elapsed += chunk_ms
            remaining = context.get_remaining_time_in_millis()

            logger.info(json.dumps({
                "event": "delay_progress",
                "elapsed_ms": elapsed,
                "remaining_lambda_ms": remaining,
                "timestamp": datetime.datetime.utcnow().isoformat()
            }))

            # If we're going to time out, log it explicitly
            # This helps the DevOps Agent correlate the timeout with the delay
            if remaining < chunk_ms + 200:
                logger.error(json.dumps({
                    "event": "imminent_timeout",
                    "elapsed_ms": elapsed,
                    "remaining_ms": remaining,
                    "message": "Lambda will timeout before completing — investigate ARTIFICIAL_DELAY_MS vs timeout config"
                }))
                break

    # If we get here (we won't in chaos mode), return success
    logger.info(json.dumps({
        "event": "invocation_complete",
        "request_id": request_id,
        "timestamp": datetime.datetime.utcnow().isoformat()
    }))

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "message": "Response from slow downstream",
            "request_id": request_id,
            "environment": environment,
            "chaos_mode": chaos_mode
        })
    }
