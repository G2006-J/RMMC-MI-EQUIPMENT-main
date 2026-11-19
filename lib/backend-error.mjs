export const PENDING_BORROWER_MESSAGE =
  "No active borrower record is linked to your account. An administrator or property custodian must approve your borrower access before you can submit or view borrowing requests.";

export function getErrorMessage(error) {
  const message =
    typeof error?.message === "string" && error.message.trim()
      ? error.message.trim()
      : "Something went wrong. Please try again.";
  const details =
    typeof error?.details === "string" && error.details.trim()
      ? error.details.trim()
      : "";
  const hint =
    typeof error?.hint === "string" && error.hint.trim()
      ? error.hint.trim()
      : "";
  const code =
    typeof error?.code === "string" && error.code.trim()
      ? error.code.trim()
      : "";

  if (/Your borrower account is pending approval or inactive|No active borrower record matches your signed-in email/i.test(message)) {
    console.error("A borrower request was blocked by account access:", {
      message,
      details,
      hint,
      code,
    });
    return PENDING_BORROWER_MESSAGE;
  }
  if (/email rate limit exceeded|too many requests/i.test(message)) {
    return "Email delivery is temporarily limited. Please try again later.";
  }
  if (/error sending confirmation email|error sending.*email/i.test(message)) {
    return "The confirmation email could not be sent. Please try again later.";
  }
  if (
    details
    || hint
    || /^[0-9A-Z]{5}$/i.test(code)
    || /permission denied|violates .*constraint|row-level security|relation .* does not exist|column .* does not exist|schema cache|could not find the .* function|function .* does not exist|sqlstate|postgres|database error|failed to fetch|fetch failed|pgrst/i.test(message)
  ) {
    console.error("A backend operation failed:", {
      message,
      details,
      hint,
      code,
    });
    return "The action could not be completed. Please try again.";
  }
  return message;
}
