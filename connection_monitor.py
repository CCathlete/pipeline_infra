import time
import requests
import subprocess
from typing import Any
from returns.result import Result, Success, Failure

# --- Configuration ---
WEBHOOK_URL = "YOUR_GOOGLE_CHAT_WEBHOOK_URL"
NGROK_API_URL = "http://localhost:4040/api/tunnels"
# ---------------------


def get_ngrok_url() -> Result[str, str]:
    """Queries ngrok API and returns Result with URL or error message."""
    try:
        response = requests.get(NGROK_API_URL, timeout=5)
        response.raise_for_status()
        data: dict[str, Any] = response.json()

        tunnels = data.get('tunnels', [])
        if not tunnels:
            return Failure("Ngrok API returned no active tunnels.")

        return Success(tunnels[0].get('public_url', 'No public_url in response'))

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
    print(f"Attempting to reset ngrok container due to: {error}")
    return terraform_apply()

# --- Main Logic ---


def run_monitor() -> None:
    print("Starting ngrok monitor...")
    max_retries = 5
    retry_delay = 300  # 5 minutes in seconds

    for attempt in range(max_retries):
        print(f"Attempt {attempt + 1} of {max_retries}")
        current_url_result = get_ngrok_url()

        match current_url_result:
            case Success(url):
                print(f"Ngrok is active with URL: {url}")
                chat_status = send_to_google_chat(url)
                match chat_status:
                    case Success(_):
                        print(f"URL sent to Google Chat: {url}")
                        return  # Success, exit the loop
                    case Failure(err):
                        print(f"Failed to send to Google Chat: {err}")
                    case _:
                        pass
            case Failure(error):
                print(f"Ngrok is down: {error}")
                reset_result = current_url_result.lash(  # type: ignore
                    reset_on_failure
                )

                match reset_result:
                    case Success(_):
                        print("Terraform reset successful.")
                        new_url_result = get_ngrok_url()
                        match new_url_result:
                            case Success(new_url):
                                send_to_google_chat(new_url)
                                print(
                                    f"🔄 Reset complete. New URL sent to chat: {new_url}")
                                return  # Success, exit the loop
                            case Failure(post_reset_error):
                                print(
                                    f"Still can't get URL after reset: {post_reset_error}")
                            case _:
                                pass
                    case Failure(reset_error):
                        print(
                            f"CRITICAL: Terraform reset failed: {reset_error}")
                    case _:
                        pass

            case _: pass

        if attempt < max_retries - 1:
            print(f"Waiting {retry_delay} seconds before retry...")
            time.sleep(retry_delay)

    print("Max retries reached. Exiting.")


if __name__ == "__main__":
    run_monitor()
