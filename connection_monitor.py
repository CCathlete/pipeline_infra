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


def get_ngrok_urls() -> Result[dict[str, str], str]:
    """Queries ngrok API and returns Result with URL or error message."""
    try:
        response = requests.get(NGROK_API_URL, timeout=5)
        response.raise_for_status()
        data: dict[str, Any] = response.json()
        tunnel_list: list[dict[str, Any]] = data.get('tunnelListResource', [])
        if not tunnel_list:
            return Failure("Ngrok API returned no active tunnels.")
        uris: dict[str, str] = {
            tunnel.get('Name', ''): tunnel.get('URI', '') for tunnel in tunnel_list
        }
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

# --- Extracted Monadic Function ---


def monitor_until_stopped(
    initial_uris: dict[str, str],
    last_openwebui: str
) -> Result[None, str]:
    """
    Performs the infinite monitoring loop.
    Returns Success(None) only if explicitly stopped (not used in this logic),
    but primarily returns Failure(err) when the loop cannot continue 
    (e.g., ngrok API fails).
    """
    current_uris: dict[str, str] = initial_uris

    while True:
        # 1. Check if the specific URL of interest has changed
        current_openwebui = current_uris.get("openwebui", "")
        if current_openwebui != last_openwebui:
            # Send notification.
            chat_res: Result[None, str] = send_to_google_chat(
                str(current_uris)
            )

            match chat_res:
                case Success(_):
                    logger.info(f"URLs sent to Google Chat: {current_uris}")
                    # Update last known state
                    last_openwebui = current_openwebui
                case Failure(err):
                    # If chat fails, we consider this a loop-breaking error
                    logger.error(f"Failed to send to Google Chat: {err}")
                    return Failure(err)
                case _: pass

        # 2 min timeout until next polling.
        time.sleep(120)
        # 2. Poll for new URLs
        next_url_res: Result[dict[str, str], str] = get_ngrok_urls()
        match next_url_res:
            case Success(new_uris):
                current_uris = new_uris
                logger.info(f"Ngrok is active with URLs: {current_uris}")
            case Failure(err):
                # API polling failed. Break the loop to allow outer retries/reset.
                logger.error(f"Failed to get uris inside monitor: {err}")
                return Failure(err)
            case _: pass


# --- Main Orchestrator ---

def run_monitor() -> None:
    logger.info("Starting ngrok monitor...")
    max_retries = 5
    retry_delay = 300  # 5 minutes
    quick_retries = 3  # Number of quick retries before terraform

    for attempt in range(max_retries):
        logger.info(f"Attempt {attempt + 1} of {max_retries}")

        # --- Phase 1: Quick Retries (Inner Loop) ---
        for quick_attempt in range(quick_retries):
            logger.info(f"Quick retry {quick_attempt + 1} of {quick_retries}")

            current_url_result = get_ngrok_urls()

            match current_url_result:
                case Success(uris):
                    logger.info(f"Ngrok is active with URLs: {uris}")

                    # Call the extracted function.
                    # It runs until it fails (e.g., API goes down) or we Ctrl+C.
                    monitor_result = monitor_until_stopped(
                        uris, uris.get("openwebui", ""))

                    match monitor_result:
                        case Failure(error):
                            # The monitor loop broke because of an error (API unreachable).
                            # We fall through to the quick-retry delay/continuation.
                            continue
                        case _: pass

                case Failure(error):
                    logger.error("Ngrok is down: %s", error)

                case _:
                    pass

            # If we reached here, either we couldn't get URLs or the monitor loop broke.
            # Wait a bit before the next quick attempt.
            if quick_attempt < quick_retries - 1:
                logger.info("Waiting 10 seconds before next quick retry...")
                time.sleep(10)

        # --- Phase 2: Terraform Reset (Outer Retry) ---

        # Check if we succeeded in the quick loop (i.e., we are currently monitoring).
        # In this specific logic, if `get_ngrok_urls` succeeded, `monitor_until_stopped`
        # would be running. If we exit the quick loop, it means we consistently failed.

        logger.warning("Quick retries failed, attempting terraform reset...")

        # We need a current Result to call lash on.
        # We re-fetch here to pass the current state to the recovery function.
        current_result = get_ngrok_urls()

        # lash: If Failure, run the function. If Success, return Success.
        reset_result: Result[None, str] = current_result.lash(  # type: ignore
            reset_on_failure)  # type: ignore

        match reset_result:
            case Success(_):
                logger.info("Terraform reset successful.")
                # After reset, verify we can get URLs immediately
                new_url_result = get_ngrok_urls()
                match new_url_result:
                    case Success(new_uris):
                        send_to_google_chat(f"{new_uris}")
                        logger.info(
                            f"Reset complete. New URL sent to chat: {new_uris}")
                        # Technically we should restart monitoring here,
                        # but to match original logic we exit on success.
                    case Failure(post_reset_error):
                        logger.error(
                            f"Still can't get URL after reset: {post_reset_error}")
                        # Loop continues to next outer attempt
                    case _: pass

            case Failure(reset_error):
                logger.error(
                    f"CRITICAL: Terraform reset failed: {reset_error}")
            case _: pass

        # --- Phase 3: Backoff ---
        if attempt < max_retries - 1:
            logger.info(
                f"Waiting {retry_delay} seconds before next major retry...")
            time.sleep(retry_delay)

    logger.error("Max retries reached. Exiting.")


if __name__ == "__main__":
    run_monitor()
