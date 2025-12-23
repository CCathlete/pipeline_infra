import time
import requests
import subprocess
import structlog
from typing import Any
from returns.result import Result, Success, Failure

# --- Configuration ---
WEBHOOK_URL = "YOUR_GOOGLE_CHAT_WEBHOOK_URL"
NGROK_API_URL = "http://localhost:4040/api/tunnels"
logger: structlog.stdlib.BoundLogger = structlog.get_logger()
# ---------------------


def get_ngrok_url() -> Result[list[str], str]:
    """Queries ngrok API and returns Result with URL or error message."""
    try:
        response = requests.get(NGROK_API_URL, timeout=5)
        response.raise_for_status()
        data: dict[str, Any] = response.json()
        tunnel_list: list[dict[str, Any]] = data.get('tunnelListResource', [])
        if not tunnel_list:
            return Failure("Ngrok API returned no active tunnels.")
        uris: list[str] = [tunnel.get('URI', '') for tunnel in tunnel_list]
        return Success(uris)
    except requests.exceptions.RequestException as e:
        return Failure(f"Ngrok API unreachable: {e}")


def terraform_apply() -> Result[None, str]:
    """Runs 'terraform apply' and returns a Result."""
    try:
        subprocess.run(
            ["terraform", "apply", "-auto-approve"],
            cwd="data/terraform",
            check=True,
            capture_output=True
        )
        return Success(None)
    except subprocess.CalledProcessError as e:
        error_message = e.stderr.decode().strip() or str(e)
        return Failure(f"Terraform apply failed: {error_message}")


def send_to_google_chat(message: str) -> Result[None, str]:
    """Sends a message to Google Chat."""
    try:
        response = requests.post(
            WEBHOOK_URL,
            json={"text": message},
            timeout=10
        )
        response.raise_for_status()
        return Success(None)
    except requests.exceptions.RequestException as e:
        return Failure(f"Failed to send to Google Chat: {e}")


def reset_on_failure(error: str) -> Result[None, str]:
    """Rescue function: attempts to reset via Terraform."""
    logger.info(f"Attempting to reset ngrok container due to: {error}")
    return terraform_apply()


def run_monitor() -> None:
    logger.info("Starting ngrok monitor...")
    max_retries = 5
    retry_delay = 300  # 5 minutes in seconds
    quick_retries = 3  # Number of quick retries before terraform

    for attempt in range(max_retries):
        logger.info(f"Attempt {attempt + 1} of {max_retries}")

        for quick_attempt in range(quick_retries):
            logger.info(f"Quick retry {quick_attempt + 1} of {quick_retries}")
            current_url_result = get_ngrok_url()

            match current_url_result:
                case Success(uris):
                    logger.info(f"Ngrok is active with URLs: {uris}")
                    chat_status = send_to_google_chat('\n'.join(uris))
                    match chat_status:
                        case Success(_):
                            logger.info(f"URLs sent to Google Chat: {uris}")
                            break
                        case Failure(err):
                            logger.error(
                                f"Failed to send to Google Chat: {err}")
                        case _:
                            pass

                case Failure(error):
                    logger.error(f"Ngrok is down: {error}")
                    if quick_attempt < quick_retries - 1:
                        logger.info(
                            "Waiting 10 seconds before next quick retry...")
                        time.sleep(10)
                    continue
                case _:
                    pass

            # If we got here, quick retries didn't work
            # Now try terraform reset
            logger.warning(
                "Quick retries failed, attempting terraform reset...")
            reset_result: Result[list[str], str] = current_url_result.lash(  # type: ignore
                reset_on_failure   # type: ignore
            )

            match reset_result:
                case Success(_):
                    logger.info("Terraform reset successful.")
                    new_url_result = get_ngrok_url()
                    match new_url_result:
                        case Success(new_uris):
                            send_to_google_chat('\n'.join(new_uris))
                            logger.info(
                                f"Reset complete. New URL sent to chat: {new_uris}")
                            return  # Success, exit the loop
                        case Failure(post_reset_error):
                            logger.error(
                                f"Still can't get URL after reset: {post_reset_error}")
                        case _:
                            pass
                case Failure(reset_error):
                    logger.error(
                        f"CRITICAL: Terraform reset failed: {reset_error}")
                case _:
                    pass

        if attempt < max_retries - 1:
            logger.info(
                f"Waiting {retry_delay} seconds before next major retry...")
            time.sleep(retry_delay)

    logger.error("Max retries reached. Exiting.")


if __name__ == "__main__":
    run_monitor()
